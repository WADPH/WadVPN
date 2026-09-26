#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/clients.sh
source "$SCRIPT_DIR/lib/clients.sh"

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
  manage-clients.sh group <command> ...     Manage client groups.

Commands:
  add, create       Create a new client. "create" is an alias for "add".
  remove, delete    Remove a client. "delete" is an alias for "remove".
  list              Show client names, addresses, protection, and groups.
  group, groups     Manage groups (see below). "groups" alone lists them.

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

Group names use letters, digits, "_" and "-", up to 22 characters.

Add options:
  --protected       Mark the client as protected from normal removal.
  --group <name>    Add the client to an existing group; can be repeated.
                    Without --group the client is isolated.
  --route <CIDR>    Route a network through this client; can be repeated.
  --ip <IPv4>       Assign a specific client IPv4 address.

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
    done < <(jq -r '.clients[]? | [.name, .address, ((.enabled // true)|tostring), ((.protected // false)|tostring), ((.groups // [])|tojson)] | @tsv' "$CLIENTS_JSON")
}

resolve_client_name() {
    local selection="$1"
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
        jq -r --argjson index "$selection" '.clients[$index - 1].name' "$CLIENTS_JSON"
    else
        echo "$selection"
    fi
}

create_client() {
    local client_name="$1"
    local protected="$2"
    local client_address="$3"
    local groups_json="$4"
    shift 4
    local routes=("$@")

    if client_exists "$client_name"; then
        echo "Client already exists." >&2
        return 1
    fi

    local group
    while IFS= read -r group; do
        require_group "$group" || return 1
    done < <(jq -r '.[]' <<< "$groups_json")

    local vpn_prefix cidr used_ips next_ip routes_json public_key server_public_key
    vpn_prefix=$(echo "$WADVPN_VPN_NETWORK" | awk -F. '{print $1"."$2"."$3}')
    cidr=$(echo "$WADVPN_VPN_NETWORK" | awk -F/ '{print $2}')

    if [ -z "$client_address" ]; then
        used_ips=$(jq -r '.clients[]?.address // empty' "$CLIENTS_JSON" | awk -F. '{print $4}' | sort -n)
        next_ip=2
        while echo "$used_ips" | grep -q "^$next_ip$"; do
            next_ip=$((next_ip + 1))
        done
        client_address="$vpn_prefix.$next_ip"
    else
        if ! echo "$client_address" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
            echo "Invalid IP address: $client_address" >&2
            return 1
        fi
        if jq -e --arg addr "$client_address" '.clients[]? | select(.address == $addr)' "$CLIENTS_JSON" >/dev/null 2>&1; then
            echo "IP address already in use: $client_address" >&2
            return 1
        fi
    fi

    if [ ${#routes[@]} -eq 0 ]; then
        routes_json='[]'
    else
        routes_json=$(printf '%s\n' "${routes[@]}" | jq -R . | jq -s -c '.')
    fi
    local client_dir="$CLIENTS_DIR/$client_name"
    mkdir -p "$client_dir" "$CLIENT_CONFIGS_DIR" "$QR_DIR"

    umask 077
    wg genkey | tee "$client_dir/private.key" | wg pubkey > "$client_dir/public.key"
    chmod 600 "$client_dir/private.key" "$client_dir/public.key"

    public_key=$(cat "$client_dir/public.key")
    server_public_key=$(cat "$CONFIG_DIR/keys/server_public.key")

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

    local client_config_path="$CLIENT_CONFIGS_DIR/$client_name.conf"
    local dns_servers="${WADVPN_DNS_SERVERS//,/\, }"
    cat > "$client_config_path" <<EOF_CONFIG
[Interface]
PrivateKey = $(cat "$client_dir/private.key")
Address = $client_address/$cidr
DNS = $dns_servers

[Peer]
PublicKey = $server_public_key
Endpoint = $WADVPN_ENDPOINT:$WADVPN_WG_LISTEN_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF_CONFIG

    local qr_path="$QR_DIR/$client_name.png"
    qrencode -t PNG -o "$qr_path" < "$client_config_path"

    echo "Client created successfully."
    echo "Name       : $client_name"
    echo "IP         : $client_address"
    echo "Protected  : $protected"
    echo "Groups     : $(format_groups <<< "$groups_json")"
    echo "Routes     : ${routes[*]:-none}"
    echo "Config     : $client_config_path"
    echo "QR PNG     : $qr_path"
    echo
    echo "To view the client config:"
    echo "  cat $client_config_path"
    echo "To download the config from the server:"
    echo "  scp root@$(hostname -I | awk '{print $1}'):$client_config_path ./"
    echo "To view the QR in terminal:"
    echo "  qrencode -t ANSIUTF8 < $client_config_path"
    echo
    echo "ASCII QR:"
    qrencode -t ANSIUTF8 "$client_config_path"
}

remove_client() {
    local client_name="$1"
    local force="$2"
    local assume_yes="$3"

    if ! jq -e --arg name "$client_name" '.clients[]? | select(.name == $name)' "$CLIENTS_JSON" >/dev/null 2>&1; then
        echo "Client not found: $client_name" >&2
        return 1
    fi

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

    while IFS= read -r route; do
        [ -n "$route" ] || continue
        ip route del "$route" dev "$WADVPN_WG_INTERFACE" 2>/dev/null || true
    done < <(jq -r --arg name "$client_name" '.clients[]? | select(.name == $name) | .routes[]?' "$CLIENTS_JSON")

    local tmp
    tmp=$(mktemp)
    jq --arg name "$client_name" '.clients |= map(select(.name != $name))' "$CLIENTS_JSON" > "$tmp"
    mv "$tmp" "$CLIENTS_JSON"

    rm -rf "$CLIENTS_DIR/$client_name"
    rm -f "$CLIENT_CONFIGS_DIR/$client_name.conf"
    rm -f "$QR_DIR/$client_name.png"

    if [ -f "$PORT_FORWARDS_JSON" ]; then
        local removed_forwards
        removed_forwards=$(jq -c --arg name "$client_name" '[.port_forwards[]? | select(.client_name == $name)]' "$PORT_FORWARDS_JSON")
        if [ "$removed_forwards" != "[]" ]; then
            tmp=$(mktemp)
            jq --arg name "$client_name" '.port_forwards |= map(select(.client_name != $name))' "$PORT_FORWARDS_JSON" > "$tmp"
            mv "$tmp" "$PORT_FORWARDS_JSON"
            echo "Removed port forwards for client '$client_name':"
            echo "$removed_forwards" | jq -r '.[] | "  - \(.id) \(.protocol) \(.external_port) -> \(.client_address):\(.client_port)"'
        fi
    fi

    "$SCRIPT_DIR/internal/apply-wireguard.sh"
    echo "Client removed: $client_name"
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
    local choice
    echo "WadVPN client management"
    echo "  1) Add client"
    echo "  2) Remove client"
    echo "  3) List clients"
    echo "  4) Manage groups"
    echo "  5) Help"
    echo "  0) Exit"
    read -r -p "Select an action: " choice
    case "$choice" in
        1) run_add_interactive ;;
        2) run_remove_interactive ;;
        3) list_clients ;;
        4) group_menu ;;
        5) usage ;;
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
        group|groups) parse_group "$@" ;;
        *) echo "Unknown command: $command" >&2; usage >&2; return 1 ;;
    esac
}

main "$@"
