#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/clients.sh
source "$SCRIPT_DIR/lib/clients.sh"
# shellcheck source=lib/net.sh
source "$SCRIPT_DIR/lib/net.sh"

CLIENTS_DIR="$PROJECT_DIR/clients"
CONFIG_DIR="$PROJECT_DIR/config"
GENERATED_DIR="$PROJECT_DIR/generated"
CLIENT_CONFIGS_DIR="$GENERATED_DIR/client-configs"
QR_DIR="$GENERATED_DIR/qr"
PORT_FORWARDS_JSON="$CONFIG_DIR/port-forwards.json"

usage() {
    cat <<'EOF'
Usage:
  manage-clients.sh                         Open the interactive client menu.
  manage-clients.sh add <name> [options]    Create a client.
  manage-clients.sh remove <name> [options] Remove a client.
  manage-clients.sh list                    List registered clients.
  manage-clients.sh enable <name>           Allow a disabled client to connect.
  manage-clients.sh disable <name>          Block a client without deleting it.
  manage-clients.sh show-config <name>      Regenerate and show config and QR.
  manage-clients.sh group <command> ...     Manage client groups.
  manage-clients.sh rotate-server-key       Replace the server key pair.

Commands:
  add, create       Create a new client. "create" is an alias for "add".
  remove, delete    Remove a client. "delete" is an alias for "remove".
  list              Show client names, addresses, protection, and groups.
  enable, disable   Turn a client on or off. A disabled client keeps its keys,
                    groups, and port forwards but cannot connect.
  show-config       Rebuild the client config and QR from current settings,
                    then print both.
  group, groups     Manage groups (see below). "groups" alone lists them.
  rotate-server-key Generate a new server key pair, apply it, and rebuild all
                    client configs. Every client must then update the server
                    public key. Use --yes to skip the confirmation.

Clients can reach each other only when they share at least one group.
A client without groups is isolated from all other VPN clients.

Group commands:
  group list                                List groups and their members.
  group create <group>                      Create an empty group.
  group rename <group> <new-name>           Rename a group, keeping members.
  group delete <group> [--yes]              Delete a group; clients stay.
  group add-client <group> <client>         Add a client to a group.
  group remove-client <group> <client>      Remove a client from a group.
  group move-client <client> <from> <to>    Move a client between groups.

Client names start with a letter or digit and use letters, digits, ".", "_"
and "-", up to 32 characters. Group names use letters, digits, "_" and "-",
up to 22 characters.

Add options:
  --protected       Mark the client as protected from normal removal.
  --group <name>    Add the client to an existing group; can be repeated.
                    Without --group the client is isolated.
  --route <CIDR>    Route a network through this client; can be repeated.
  --ip <IPv4>       Assign a specific address inside the VPN network.

Remove options:
  --force           Allow removal of a protected client.
  --yes, -y         Do not ask for deletion confirmation.

General options:
  --help, -h        Show this help message.

Examples:
  sudo ./scripts/manage-clients.sh add laptop --group home --group office
  sudo ./scripts/manage-clients.sh add router --protected --route 192.168.50.0/24
  sudo ./scripts/manage-clients.sh remove laptop --yes
  sudo ./scripts/manage-clients.sh remove router --force --yes
  sudo ./scripts/manage-clients.sh disable laptop
  sudo ./scripts/manage-clients.sh show-config laptop
  sudo ./scripts/manage-clients.sh group create office
  sudo ./scripts/manage-clients.sh group move-client laptop home office
EOF
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Run this script as root." >&2
        exit 1
    fi
}

format_groups() {
    jq -r 'if length == 0 then "none (isolated from all clients)" else join(", ") end'
}

list_clients() {
    echo "Available clients:"
    echo "  #  Name          Address          Enabled  Protected  Groups"
    local idx=1
    while IFS=$'\t' read -r name address enabled protected groups; do
        [ "$enabled" = "true" ] && enabled="yes" || enabled="no"
        [ "$protected" = "true" ] && protected="yes" || protected="no"
        printf '  %2s  %-12s  %-15s  %-7s  %-9s  %s\n' "$idx" "$name" "$address" "$enabled" "$protected" "$(format_groups <<< "$groups")"
        idx=$((idx + 1))
    done < <(jq -r '.clients[]? | [.name, .address, ((.enabled != false)|tostring), ((.protected // false)|tostring), ((.groups // [])|tojson)] | @tsv' "$CLIENTS_JSON")
}

resolve_client_name() {
    local selection="$1"
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
        jq -r --argjson index "$selection" '.clients[$index - 1].name' "$CLIENTS_JSON"
    else
        echo "$selection"
    fi
}

require_valid_client_name() {
    valid_client_name "$1" && return 0
    echo "Invalid client name: $1 (start with a letter or digit; use letters, digits, ., _ and -, up to 32 characters)" >&2
    return 1
}

server_address() {
    echo "${WADVPN_WG_ADDRESS%/*}"
}

address_in_use() {
    jq -e --arg addr "$1" '.clients[]? | select(.address == $addr)' "$CLIENTS_JSON" >/dev/null 2>&1
}

# The allocator hands out host addresses of the /24 VPN network, skipping the
# server address and addresses already assigned.
allocate_address() {
    local vpn_prefix candidate host
    vpn_prefix=$(echo "${WADVPN_VPN_NETWORK%/*}" | awk -F. '{print $1"."$2"."$3}')
    for host in $(seq 2 254); do
        candidate="$vpn_prefix.$host"
        [ "$candidate" != "$(server_address)" ] || continue
        address_in_use "$candidate" && continue
        echo "$candidate"
        return 0
    done
    echo "No free address left in $WADVPN_VPN_NETWORK." >&2
    return 1
}

validate_client_address() {
    local address="$1" prefix network_int broadcast_int address_int
    if ! valid_ipv4 "$address" || ! cidr_contains "$WADVPN_VPN_NETWORK" "$address"; then
        echo "Address must be an IPv4 address inside $WADVPN_VPN_NETWORK: $address" >&2
        return 1
    fi
    prefix="${WADVPN_VPN_NETWORK#*/}"
    network_int=$(ipv4_to_int "${WADVPN_VPN_NETWORK%/*}")
    broadcast_int=$(( network_int | ((1 << (32 - prefix)) - 1) ))
    address_int=$(ipv4_to_int "$address")
    if [ "$address_int" -eq "$network_int" ] || [ "$address_int" -eq "$broadcast_int" ]; then
        echo "Address is the network or broadcast address: $address" >&2
        return 1
    fi
    if [ "$address" = "$(server_address)" ]; then
        echo "Address belongs to the VPN server: $address" >&2
        return 1
    fi
    if address_in_use "$address"; then
        echo "IP address already in use: $address" >&2
        return 1
    fi
}

# Writes the client config and QR image from the registry, the client's own
# private key, and the current server public key.
write_client_files() {
    local client_name="$1"
    local private_key_path="$CLIENTS_DIR/$client_name/private.key"
    if [ ! -f "$private_key_path" ]; then
        echo "Private key not found for client '$client_name': $private_key_path" >&2
        return 1
    fi

    local client_address config_path
    client_address=$(jq -r --arg name "$client_name" '.clients[] | select(.name == $name) | .address' "$CLIENTS_JSON")
    config_path="$CLIENT_CONFIGS_DIR/$client_name.conf"
    mkdir -p "$CLIENT_CONFIGS_DIR" "$QR_DIR"

    # ::/0 sends IPv6 into the tunnel too.  The server accepts only IPv4 from
    # peers, so IPv6 is dropped there instead of leaking outside the VPN.
    (
        umask 077
        cat > "$config_path" <<EOF_CONFIG
[Interface]
PrivateKey = $(cat "$private_key_path")
Address = $client_address/${WADVPN_VPN_NETWORK#*/}
DNS = ${WADVPN_DNS_SERVERS//,/, }

[Peer]
PublicKey = $(cat "$CONFIG_DIR/keys/server_public.key")
Endpoint = $WADVPN_ENDPOINT:$WADVPN_WG_LISTEN_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF_CONFIG
        qrencode -t PNG -o "$QR_DIR/$client_name.png" < "$config_path"
    )
}

print_client_files() {
    local client_name="$1"
    local config_path="$CLIENT_CONFIGS_DIR/$client_name.conf"
    echo "Config     : $config_path"
    echo "QR PNG     : $QR_DIR/$client_name.png"
    echo
    echo "To download the config from the server:"
    echo "  scp root@$(hostname -I | awk '{print $1}'):$config_path ./"
    echo
    cat "$config_path"
    echo
    echo "ASCII QR:"
    qrencode -t ANSIUTF8 < "$config_path"
}

create_client() {
    local client_name="$1"
    local protected="$2"
    local client_address="$3"
    local groups_json="$4"
    shift 4
    local routes=("$@")

    require_valid_client_name "$client_name" || return 1
    if client_exists "$client_name"; then
        echo "Client already exists." >&2
        return 1
    fi

    local group
    while IFS= read -r group; do
        require_group "$group" || return 1
    done < <(jq -r '.[]' <<< "$groups_json")

    local route valid_routes=()
    for route in "${routes[@]}"; do
        route="${route// /}"
        [ -n "$route" ] || continue
        valid_ipv4_cidr "$route" || { echo "Invalid route (expected IPv4 CIDR such as 192.168.50.0/24): $route" >&2; return 1; }
        valid_routes+=("$route")
    done

    if [ -z "$client_address" ]; then
        client_address=$(allocate_address) || return 1
    else
        validate_client_address "$client_address" || return 1
    fi

    local routes_json public_key
    routes_json=$(to_json_array "${valid_routes[@]}")
    local client_dir="$CLIENTS_DIR/$client_name"
    mkdir -p "$client_dir"

    (
        umask 077
        wg genkey | tee "$client_dir/private.key" | wg pubkey > "$client_dir/public.key"
    )
    public_key=$(cat "$client_dir/public.key")

    update_clients_json \
        --arg name "$client_name" \
        --arg addr "$client_address" \
        --arg key "$public_key" \
        --argjson protected "$protected" \
        --argjson routes "$routes_json" \
        --argjson groups "$groups_json" \
        '.clients += [{
            "name": $name,
            "enabled": true,
            "address": $addr,
            "public_key": $key,
            "protected": $protected,
            "routes": $routes,
            "groups": $groups
        }]'

    "$SCRIPT_DIR/internal/apply-wireguard.sh"
    write_client_files "$client_name"

    echo "Client created successfully."
    echo "Name       : $client_name"
    echo "IP         : $client_address"
    echo "Protected  : $protected"
    echo "Groups     : $(format_groups <<< "$groups_json")"
    echo "Routes     : ${valid_routes[*]:-none}"
    print_client_files "$client_name"
}

delete_client_routes() {
    local route
    while IFS= read -r route; do
        [ -n "$route" ] || continue
        ip route del "$route" dev "$WADVPN_WG_INTERFACE" 2>/dev/null || true
    done < <(jq -r --arg name "$1" '.clients[]? | select(.name == $name) | .routes[]?' "$CLIENTS_JSON")
}

remove_client() {
    local client_name="$1"
    local force="$2"
    local assume_yes="$3"

    require_client "$client_name" || return 1
    # The name becomes part of the paths removed below; never trust a
    # hand-edited registry.
    require_valid_client_name "$client_name" || return 1

    if [ "$(jq -r --arg name "$client_name" '.clients[]? | select(.name == $name) | (.protected // false)' "$CLIENTS_JSON")" = "true" ] && [ "$force" != true ]; then
        echo "Protected client cannot be removed: $client_name" >&2
        echo "Use --force to remove it anyway." >&2
        return 1
    fi

    if [ "$assume_yes" != true ]; then
        local confirm
        read -r -p "Remove client '$client_name'? [y/N] " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo "Aborted."
            return 0
        fi
    fi

    delete_client_routes "$client_name"
    update_clients_json --arg name "$client_name" '.clients |= map(select(.name != $name))'

    rm -rf "${CLIENTS_DIR:?}/${client_name:?}"
    rm -f "${CLIENT_CONFIGS_DIR:?}/${client_name:?}.conf"
    rm -f "${QR_DIR:?}/${client_name:?}.png"

    if [ -f "$PORT_FORWARDS_JSON" ]; then
        local removed_forwards tmp
        removed_forwards=$(jq -c --arg name "$client_name" '[.port_forwards[]? | select(.client_name == $name)]' "$PORT_FORWARDS_JSON")
        if [ "$removed_forwards" != "[]" ]; then
            tmp=$(mktemp "$PORT_FORWARDS_JSON.XXXXXX")
            jq --arg name "$client_name" '.port_forwards |= map(select(.client_name != $name))' "$PORT_FORWARDS_JSON" > "$tmp"
            chmod --reference="$PORT_FORWARDS_JSON" "$tmp"
            chown --reference="$PORT_FORWARDS_JSON" "$tmp" 2>/dev/null || true
            mv "$tmp" "$PORT_FORWARDS_JSON"
            echo "Removed port forwards for client '$client_name':"
            echo "$removed_forwards" | jq -r '.[] | "  - \(.id) \(.protocol) \(.external_port) -> port \(.client_port)"'
        fi
    fi

    "$SCRIPT_DIR/internal/apply-wireguard.sh"
    echo "Client removed: $client_name"
}

set_client_enabled() {
    local client_name="$1" enabled="$2"
    require_client "$client_name" || return 1
    if jq -e --arg name "$client_name" --argjson enabled "$enabled" '.clients[] | select(.name == $name) | (.enabled != false) == $enabled' "$CLIENTS_JSON" >/dev/null; then
        echo "Client '$client_name' is already $([ "$enabled" = true ] && echo enabled || echo disabled)."
        return 0
    fi

    [ "$enabled" = true ] || delete_client_routes "$client_name"
    update_clients_json --arg name "$client_name" --argjson enabled "$enabled" '
        .clients |= map(if .name == $name then .enabled = $enabled else . end)'
    "$SCRIPT_DIR/internal/apply-wireguard.sh"
    if [ "$enabled" = true ]; then
        echo "Client enabled: $client_name"
    else
        echo "Client disabled: $client_name (keys, groups, and port forwards are kept)"
    fi
}

show_client_config() {
    local client_name="$1"
    require_client "$client_name" || return 1
    require_valid_client_name "$client_name" || return 1
    write_client_files "$client_name"
    if jq -e --arg name "$client_name" '.clients[] | select(.name == $name) | (.enabled != false) | not' "$CLIENTS_JSON" >/dev/null; then
        echo "Note: client '$client_name' is disabled and cannot connect until it is enabled."
    fi
    print_client_files "$client_name"
}

# Replaces the server key pair.  Peers keep their own keys, so only the server
# public key in each client config changes.  Connected clients drop off until
# they are updated.
rotate_server_key() {
    local assume_yes="$1"
    local keys_dir="$CONFIG_DIR/keys"

    if [ "$assume_yes" != true ]; then
        local confirm
        echo "All clients will disconnect until their configs use the new server public key."
        read -r -p "Rotate the server key now? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; return 0; }
    fi

    local backup_dir old_public new_public
    backup_dir="$PROJECT_DIR/backup/server-key-rotation-$(date +%Y%m%d%H%M%S)"
    (
        umask 077
        mkdir -p "$backup_dir"
        cp -p "$keys_dir/server_private.key" "$keys_dir/server_public.key" "$backup_dir/"
        [ ! -f "$CONFIG_DIR/$WADVPN_WG_INTERFACE.conf" ] || cp -p "$CONFIG_DIR/$WADVPN_WG_INTERFACE.conf" "$backup_dir/"
        [ ! -d "$GENERATED_DIR" ] || cp -rp "$GENERATED_DIR" "$backup_dir/generated"

        wg genkey > "$keys_dir/server_private.key.new"
        wg pubkey < "$keys_dir/server_private.key.new" > "$keys_dir/server_public.key.new"
        mv "$keys_dir/server_private.key.new" "$keys_dir/server_private.key"
        mv "$keys_dir/server_public.key.new" "$keys_dir/server_public.key"
    )
    old_public=$(cat "$backup_dir/server_public.key")
    new_public=$(cat "$keys_dir/server_public.key")

    "$SCRIPT_DIR/internal/apply-wireguard.sh"

    local client_name failed=()
    echo "Rebuilt client configs:"
    while IFS= read -r client_name; do
        if valid_client_name "$client_name" && write_client_files "$client_name"; then
            echo "  $client_name: $CLIENT_CONFIGS_DIR/$client_name.conf"
        else
            failed+=("$client_name")
        fi
    done < <(jq -r '.clients[]?.name' "$CLIENTS_JSON")

    echo
    echo "Server key rotated. Backup of the previous keys: $backup_dir"
    echo "Old server public key: $old_public"
    echo "New server public key: $new_public"
    echo "On every client, set PublicKey in the [Peer] section to the new key,"
    echo "or re-import its config or QR from $GENERATED_DIR."
    if [ ${#failed[@]} -gt 0 ]; then
        echo "Configs could not be rebuilt for: ${failed[*]}" >&2
        return 1
    fi
}

client_exists() {
    jq -e --arg name "$1" '.clients[]? | select(.name == $name)' "$CLIENTS_JSON" >/dev/null 2>&1
}

group_exists() {
    jq -e --arg group "$1" '.groups | index($group)' "$CLIENTS_JSON" >/dev/null 2>&1
}

require_client() {
    client_exists "$1" || { echo "Client not found: $1" >&2; return 1; }
}

require_group() {
    group_exists "$1" || { echo "Group not found: $1 (create it with: group create $1)" >&2; return 1; }
}

client_in_group() {
    jq -e --arg name "$1" --arg group "$2" '.clients[] | select(.name == $name) | (.groups // []) | index($group)' "$CLIENTS_JSON" >/dev/null 2>&1
}

to_json_array() {
    if [ $# -eq 0 ]; then
        echo '[]'
    else
        printf '%s\n' "$@" | jq -R . | jq -s -c 'map(select(length > 0)) | unique'
    fi
}

# Group membership lives only in the firewall, so WireGuard is not restarted.
apply_group_changes() {
    "$SCRIPT_DIR/internal/apply-firewall.sh"
}

list_groups() {
    echo "Groups:"
    if jq -e '.groups | length == 0' "$CLIENTS_JSON" >/dev/null; then
        echo "  (no groups)"
    fi
    local idx=1 group count members
    while IFS=$'\t' read -r group count members; do
        printf '  %2s  %-22s  %2s client(s)  %s\n' "$idx" "$group" "$count" "$members"
        idx=$((idx + 1))
    done < <(jq -r '.clients as $clients | .groups[] | . as $group
        | [$clients[]? | select((.groups // []) | index($group)) | .name] as $members
        | [$group, ($members | length | tostring), ($members | join(", "))] | @tsv' "$CLIENTS_JSON")

    local isolated
    isolated=$(jq -r '[.clients[]? | select((.groups // []) | length == 0) | .name] | join(", ")' "$CLIENTS_JSON")
    echo
    echo "Without groups (isolated from all clients): ${isolated:-none}"
}

resolve_group_name() {
    local selection="$1"
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
        jq -r --argjson index "$selection" '.groups[$index - 1] // empty' "$CLIENTS_JSON"
    else
        echo "$selection"
    fi
}

group_create() {
    local group="$1"
    if ! valid_group_name "$group"; then
        echo "Invalid group name: $group (use letters, digits, _ and -, up to 22 characters)" >&2
        return 1
    fi
    if group_exists "$group"; then
        echo "Group already exists: $group" >&2
        return 1
    fi
    update_clients_json --arg group "$group" '.groups += [$group]'
    apply_group_changes
    echo "Group created: $group"
}

group_rename() {
    local group="$1" new_name="$2"
    require_group "$group" || return 1
    if ! valid_group_name "$new_name"; then
        echo "Invalid group name: $new_name (use letters, digits, _ and -, up to 22 characters)" >&2
        return 1
    fi
    if group_exists "$new_name"; then
        echo "Group already exists: $new_name" >&2
        return 1
    fi
    update_clients_json --arg old "$group" --arg new "$new_name" '
        .groups |= map(if . == $old then $new else . end)
        | .clients |= map(if has("groups") then .groups |= map(if . == $old then $new else . end) else . end)'
    apply_group_changes
    echo "Group renamed: $group -> $new_name"
}

group_delete() {
    local group="$1" assume_yes="$2"
    require_group "$group" || return 1

    local members orphaned
    members=$(jq -r --arg group "$group" '[.clients[]? | select((.groups // []) | index($group)) | .name] | join(", ")' "$CLIENTS_JSON")
    orphaned=$(jq -r --arg group "$group" '[.clients[]? | select((.groups // []) == [$group]) | .name] | join(", ")' "$CLIENTS_JSON")
    echo "Members of '$group': ${members:-none}"
    [ -z "$orphaned" ] || echo "These clients will have no groups and become isolated: $orphaned"

    if [ "$assume_yes" != true ]; then
        local confirm
        read -r -p "Delete group '$group'? Clients are kept. [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; return 0; }
    fi

    update_clients_json --arg group "$group" '
        .groups |= map(select(. != $group))
        | .clients |= map(if has("groups") then .groups |= map(select(. != $group)) else . end)'
    apply_group_changes
    echo "Group deleted: $group"
}

group_add_client() {
    local group="$1" client_name="$2"
    require_group "$group" || return 1
    require_client "$client_name" || return 1
    if client_in_group "$client_name" "$group"; then
        echo "Client '$client_name' is already in group '$group'."
        return 0
    fi
    update_clients_json --arg name "$client_name" --arg group "$group" '
        .clients |= map(if .name == $name then .groups = ((.groups // []) + [$group]) else . end)'
    apply_group_changes
    echo "Client '$client_name' added to group '$group'."
}

group_remove_client() {
    local group="$1" client_name="$2"
    require_group "$group" || return 1
    require_client "$client_name" || return 1
    if ! client_in_group "$client_name" "$group"; then
        echo "Client '$client_name' is not in group '$group'." >&2
        return 1
    fi
    update_clients_json --arg name "$client_name" --arg group "$group" '
        .clients |= map(if .name == $name then .groups |= map(select(. != $group)) else . end)'
    apply_group_changes
    echo "Client '$client_name' removed from group '$group'."
    if jq -e --arg name "$client_name" '.clients[] | select(.name == $name) | .groups | length == 0' "$CLIENTS_JSON" >/dev/null; then
        echo "Client '$client_name' has no groups now and is isolated from all clients."
    fi
}

group_move_client() {
    local client_name="$1" from="$2" to="$3"
    require_client "$client_name" || return 1
    require_group "$from" || return 1
    require_group "$to" || return 1
    if ! client_in_group "$client_name" "$from"; then
        echo "Client '$client_name' is not in group '$from'." >&2
        return 1
    fi
    update_clients_json --arg name "$client_name" --arg from "$from" --arg to "$to" '
        .clients |= map(if .name == $name then .groups = ((.groups | map(select(. != $from))) + [$to] | unique) else . end)'
    apply_group_changes
    echo "Client '$client_name' moved from group '$from' to '$to'."
}

parse_group() {
    local command="${1:-list}"
    [ $# -eq 0 ] || shift
    case "$command" in
        list)
            [ $# -eq 0 ] || { echo "group list accepts no arguments." >&2; return 1; }
            list_groups
            ;;
        create)
            [ $# -eq 1 ] || { echo "Usage: group create <group>" >&2; return 1; }
            group_create "$1"
            ;;
        rename)
            [ $# -eq 2 ] || { echo "Usage: group rename <group> <new-name>" >&2; return 1; }
            group_rename "$1" "$2"
            ;;
        delete|remove)
            local group="" assume_yes=false
            while [ $# -gt 0 ]; do
                case "$1" in
                    --yes|-y) assume_yes=true ;;
                    -*) echo "Unknown option: $1" >&2; return 1 ;;
                    *)
                        [ -z "$group" ] || { echo "Unexpected argument: $1" >&2; return 1; }
                        group="$1"
                        ;;
                esac
                shift
            done
            [ -n "$group" ] || { echo "Usage: group delete <group> [--yes]" >&2; return 1; }
            group_delete "$group" "$assume_yes"
            ;;
        add-client)
            [ $# -eq 2 ] || { echo "Usage: group add-client <group> <client>" >&2; return 1; }
            group_add_client "$1" "$2"
            ;;
        remove-client)
            [ $# -eq 2 ] || { echo "Usage: group remove-client <group> <client>" >&2; return 1; }
            group_remove_client "$1" "$2"
            ;;
        move-client)
            [ $# -eq 3 ] || { echo "Usage: group move-client <client> <from-group> <to-group>" >&2; return 1; }
            group_move_client "$1" "$2" "$3"
            ;;
        --help|-h) usage ;;
        *) echo "Unknown group command: $command" >&2; usage >&2; return 1 ;;
    esac
}

prompt_client() {
    local selection name
    list_clients >&2
    read -r -p "Client number or name: " selection
    name=$(resolve_client_name "$selection")
    [ -n "$name" ] && [ "$name" != null ] || { echo "Invalid selection." >&2; return 1; }
    echo "$name"
}

prompt_group() {
    local prompt="$1" selection group
    list_groups >&2
    read -r -p "$prompt" selection
    group=$(resolve_group_name "$selection")
    [ -n "$group" ] || { echo "Invalid selection." >&2; return 1; }
    echo "$group"
}

group_menu() {
    local choice group client from to new_name
    echo "Group management"
    echo "  1) List groups"
    echo "  2) Create group"
    echo "  3) Rename group"
    echo "  4) Delete group"
    echo "  5) Add client to group"
    echo "  6) Remove client from group"
    echo "  7) Move client to another group"
    echo "  0) Back"
    read -r -p "Select an action: " choice
    case "$choice" in
        1) list_groups ;;
        2)
            read -r -p "New group name: " group
            group_create "$group"
            ;;
        3)
            group=$(prompt_group "Group number or name to rename: ") || return 1
            read -r -p "New name for '$group': " new_name
            group_rename "$group" "$new_name"
            ;;
        4)
            group=$(prompt_group "Group number or name to delete: ") || return 1
            group_delete "$group" false
            ;;
        5)
            client=$(prompt_client) || return 1
            group=$(prompt_group "Add '$client' to group (number or name): ") || return 1
            group_add_client "$group" "$client"
            ;;
        6)
            client=$(prompt_client) || return 1
            echo "Current groups: $(jq -r --arg name "$client" '.clients[] | select(.name == $name) | .groups // []' "$CLIENTS_JSON" | format_groups)"
            group=$(prompt_group "Remove '$client' from group (number or name): ") || return 1
            group_remove_client "$group" "$client"
            ;;
        7)
            client=$(prompt_client) || return 1
            echo "Current groups: $(jq -r --arg name "$client" '.clients[] | select(.name == $name) | .groups // []' "$CLIENTS_JSON" | format_groups)"
            from=$(prompt_group "Move '$client' from group (number or name): ") || return 1
            to=$(prompt_group "Move '$client' to group (number or name): ") || return 1
            group_move_client "$client" "$from" "$to"
            ;;
        0) ;;
        *) echo "Invalid selection." >&2; return 1 ;;
    esac
}

run_add_interactive() {
    local name protected=false address routes_input groups_input
    local routes=() groups=()
    read -r -p "Client name: " name
    [ -n "$name" ] || { echo "Client name is required." >&2; return 1; }
    read -r -p "Protected client? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] && protected=true
    echo "Existing groups: $(jq -r '.groups | if length == 0 then "none" else join(", ") end' "$CLIENTS_JSON")"
    read -r -p "Groups, comma-separated (leave empty to isolate the client): " groups_input
    if [ -n "$groups_input" ]; then
        IFS=',' read -r -a groups <<< "${groups_input// /}"
    fi
    read -r -p "Client IP (leave empty for automatic): " address
    read -r -p "Client routes, comma-separated (optional): " routes_input
    if [ -n "$routes_input" ]; then
        IFS=',' read -r -a routes <<< "$routes_input"
    fi
    create_client "$name" "$protected" "$address" "$(to_json_array "${groups[@]}")" "${routes[@]}"
}

run_remove_interactive() {
    local selection name force=false
    list_clients
    read -r -p "Client number or name to remove: " selection
    name=$(resolve_client_name "$selection")
    if [ -z "$name" ] || [ "$name" = null ]; then
        echo "Invalid selection." >&2
        return 1
    fi
    if [ "$(jq -r --arg name "$name" '.clients[]? | select(.name == $name) | (.protected // false)' "$CLIENTS_JSON")" = "true" ]; then
        read -r -p "Client is protected. Remove anyway? [y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; return 0; }
        force=true
    fi
    remove_client "$name" "$force" false
}

interactive_menu() {
    local choice client answer
    echo "WadVPN client management"
    echo "  1) Add client"
    echo "  2) Remove client"
    echo "  3) List clients"
    echo "  4) Enable client"
    echo "  5) Disable client"
    echo "  6) Show client config and QR"
    echo "  7) Manage groups"
    echo "  8) Rotate server key"
    echo "  9) Help"
    echo "  0) Exit"
    read -r -p "Select an action: " choice
    case "$choice" in
        1) run_add_interactive ;;
        2) run_remove_interactive ;;
        3) list_clients ;;
        4) client=$(prompt_client) || return 1; set_client_enabled "$client" true ;;
        5) client=$(prompt_client) || return 1; set_client_enabled "$client" false ;;
        6) client=$(prompt_client) || return 1; show_client_config "$client" ;;
        7) group_menu ;;
        8) rotate_server_key false ;;
        9) usage ;;
        0) ;;
        *) echo "Invalid selection." >&2; return 1 ;;
    esac
}

parse_add() {
    local name="" protected=false address=""
    local routes=() groups=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --protected) protected=true ;;
            --group)
                [ $# -ge 2 ] || { echo "Missing value for --group" >&2; return 1; }
                groups+=("$2")
                shift
                ;;
            --route)
                [ $# -ge 2 ] || { echo "Missing value for --route" >&2; return 1; }
                routes+=("$2")
                shift
                ;;
            --ip)
                [ $# -ge 2 ] || { echo "Missing value for --ip" >&2; return 1; }
                address="$2"
                shift
                ;;
            --help|-h) usage; return 0 ;;
            -*) echo "Unknown option: $1" >&2; return 1 ;;
            *)
                [ -z "$name" ] || { echo "Unexpected argument: $1" >&2; return 1; }
                name="$1"
                ;;
        esac
        shift
    done
    [ -n "$name" ] || { echo "Client name is required for non-interactive add." >&2; return 1; }
    create_client "$name" "$protected" "$address" "$(to_json_array "${groups[@]}")" "${routes[@]}"
}

parse_remove() {
    local name="" force=false assume_yes=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=true ;;
            --yes|-y) assume_yes=true ;;
            --help|-h) usage; return 0 ;;
            -*) echo "Unknown option: $1" >&2; return 1 ;;
            *)
                [ -z "$name" ] || { echo "Unexpected argument: $1" >&2; return 1; }
                name="$1"
                ;;
        esac
        shift
    done
    [ -n "$name" ] || { echo "Client name is required for non-interactive remove." >&2; return 1; }
    remove_client "$name" "$force" "$assume_yes"
}

main() {
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        usage
        return 0
    fi

    require_root
    local command="${1:-}"
    if [ -z "$command" ]; then
        interactive_menu
        return
    fi
    shift

    case "$command" in
        add|create) parse_add "$@" ;;
        remove|delete) parse_remove "$@" ;;
        list) [ $# -eq 0 ] || { echo "list accepts no options." >&2; return 1; }; list_clients ;;
        enable|disable)
            [ $# -eq 1 ] || { echo "Usage: $command <client>" >&2; return 1; }
            set_client_enabled "$1" "$([ "$command" = enable ] && echo true || echo false)"
            ;;
        show-config)
            [ $# -eq 1 ] || { echo "Usage: show-config <client>" >&2; return 1; }
            show_client_config "$1"
            ;;
        group|groups) parse_group "$@" ;;
        rotate-server-key)
            case "${1:-}" in
                "") rotate_server_key false ;;
                --yes|-y) [ $# -eq 1 ] || { echo "Usage: rotate-server-key [--yes]" >&2; return 1; }; rotate_server_key true ;;
                *) echo "Usage: rotate-server-key [--yes]" >&2; return 1 ;;
            esac
            ;;
        *) echo "Unknown command: $command" >&2; usage >&2; return 1 ;;
    esac
}

main "$@"
