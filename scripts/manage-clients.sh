#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

CLIENTS_DIR="$PROJECT_DIR/clients"
CONFIG_DIR="$PROJECT_DIR/config"
GENERATED_DIR="$PROJECT_DIR/generated"
CLIENT_CONFIGS_DIR="$GENERATED_DIR/client-configs"
QR_DIR="$GENERATED_DIR/qr"
CLIENTS_JSON="$CONFIG_DIR/clients.json"
PORT_FORWARDS_JSON="$CONFIG_DIR/port-forwards.json"

usage() {
    cat <<'EOF'
Usage:
  manage-clients.sh                         Open the interactive client menu.
  manage-clients.sh add <name> [options]    Create a client.
  manage-clients.sh remove <name> [options] Remove a client.
  manage-clients.sh list                    List registered clients.

Commands:
  add, create       Create a new client. "create" is an alias for "add".
  remove, delete    Remove a client. "delete" is an alias for "remove".
  list              Show client names, addresses, and protection status.

Add options:
  --protected       Mark the client as protected from normal removal.
  --isolated        Prevent the client from reaching other VPN clients.
  --route <CIDR>    Route a network through this client; can be repeated.
  --ip <IPv4>       Assign a specific client IPv4 address.

Remove options:
  --force           Allow removal of a protected client.
  --yes, -y         Do not ask for deletion confirmation.

General options:
  --help, -h        Show this help message.

Examples:
  sudo ./scripts/manage-clients.sh add laptop
  sudo ./scripts/manage-clients.sh add router --protected --route 192.168.50.0/24
  sudo ./scripts/manage-clients.sh remove laptop --yes
  sudo ./scripts/manage-clients.sh remove router --force --yes
EOF
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Run this script as root." >&2
        exit 1
    fi
}

list_clients() {
    echo "Available clients:"
    echo "  #  Name          Address          Enabled  Protected  Isolated"
    local idx=1
    while IFS=$'\t' read -r name address enabled protected isolated; do
        [ "$enabled" = "true" ] && enabled="yes" || enabled="no"
        [ "$protected" = "true" ] && protected="yes" || protected="no"
        [ "$isolated" = "true" ] && isolated="yes" || isolated="no"
        printf '  %2s  %-12s  %-15s  %-7s  %-10s  %s\n' "$idx" "$name" "$address" "$enabled" "$protected" "$isolated"
        idx=$((idx + 1))
    done < <(jq -r '.clients[]? | [.name, .address, ((.enabled // true)|tostring), ((.protected // false)|tostring), ((.isolated // false)|tostring)] | @tsv' "$CLIENTS_JSON")
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
    local isolated="$3"
    local client_address="$4"
    shift 4
    local routes=("$@")

    if jq -e --arg name "$client_name" '.clients[]? | select(.name == $name)' "$CLIENTS_JSON" >/dev/null 2>&1; then
        echo "Client already exists." >&2
        return 1
    fi

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

    local tmp
    tmp=$(mktemp)
    jq \
        --arg name "$client_name" \
        --arg addr "$client_address" \
        --arg key "$public_key" \
        --argjson protected "$protected" \
        --argjson isolated "$isolated" \
        --argjson routes "$routes_json" \
        '.clients += [{
            "name": $name,
            "enabled": true,
            "address": $addr,
            "public_key": $key,
            "protected": $protected,
            "isolated": $isolated,
            "routes": $routes,
            "groups": []
        }]' \
        "$CLIENTS_JSON" > "$tmp"
    mv "$tmp" "$CLIENTS_JSON"

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
    echo "Isolated   : $isolated"
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

run_add_interactive() {
    local name protected=false isolated=false address routes_input
    local routes=()
    read -r -p "Client name: " name
    [ -n "$name" ] || { echo "Client name is required." >&2; return 1; }
    read -r -p "Protected client? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] && protected=true
    read -r -p "Isolate from other VPN clients? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] && isolated=true
    read -r -p "Client IP (leave empty for automatic): " address
    read -r -p "Client routes, comma-separated (optional): " routes_input
    if [ -n "$routes_input" ]; then
        IFS=',' read -r -a routes <<< "$routes_input"
    fi
    create_client "$name" "$protected" "$isolated" "$address" "${routes[@]}"
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
    echo "  4) Help"
    echo "  0) Exit"
    read -r -p "Select an action: " choice
    case "$choice" in
        1) run_add_interactive ;;
        2) run_remove_interactive ;;
        3) list_clients ;;
        4) usage ;;
        0) ;;
        *) echo "Invalid selection." >&2; return 1 ;;
    esac
}

parse_add() {
    local name="" protected=false isolated=false address=""
    local routes=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --protected) protected=true ;;
            --isolated) isolated=true ;;
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
    create_client "$name" "$protected" "$isolated" "$address" "${routes[@]}"
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
        *) echo "Unknown command: $command" >&2; usage >&2; return 1 ;;
    esac
}

main "$@"
