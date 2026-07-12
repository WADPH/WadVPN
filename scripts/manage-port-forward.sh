#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$PROJECT_DIR/config"
CLIENTS_JSON="$CONFIG_DIR/clients.json"
PORT_FORWARDS_JSON="$CONFIG_DIR/port-forwards.json"

usage() {
    cat <<'EOF'
Usage:
  manage-port-forward.sh                                  Open the interactive menu.
  manage-port-forward.sh list                             List active forwards.
  manage-port-forward.sh add <client> [options]           Add a forward.
  manage-port-forward.sh remove <id>                      Remove a forward.

Add options:
  --protocol <tcp|udp>        Protocol for the external port.
  --external-port <1-65535>   Public port on the VPN server.
  --target-port <1-65535>     Port on the target host.
  --target-address <IPv4>     Target host address. Defaults to the client VPN IP.
                              It may also be an IPv4 address inside a route
                              announced by the selected client.

General options:
  --help, -h                  Show this help message.

Examples:
  sudo ./scripts/manage-port-forward.sh add laptop \
    --protocol tcp --external-port 443 --target-port 8443
  sudo ./scripts/manage-port-forward.sh add router \
    --protocol tcp --external-port 80 --target-address 192.168.50.10 --target-port 80
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
    jq -r '.clients[]? | [.name, .address, ((.enabled // true)|tostring), ([.routes[]?] | join(", "))] | @tsv' "$CLIENTS_JSON" | nl -ba | sed 's/\t/  /g'
}

list_forwards() {
    echo "Active port forwards:"
    local count
    count=$(jq '[.port_forwards[]? | select(.id != null)] | length' "$PORT_FORWARDS_JSON")
    if [ "$count" -gt 0 ]; then
        jq -r '.port_forwards[]? | select(.id != null) | ["ID=\(.id)", "Client=\(.client_name)", "Proto=\(.protocol)", "External=\(.external_port)", "Target=\(.target_address // .client_address):\(.client_port)"] | @tsv' "$PORT_FORWARDS_JSON"
    else
        echo "  (none)"
    fi
}

list_forward_choices() {
    echo "Available port forwards:"
    local count
    count=$(jq '[.port_forwards[]? | select(.id != null)] | length' "$PORT_FORWARDS_JSON")
    if [ "$count" -gt 0 ]; then
        jq -r '.port_forwards[]? | select(.id != null) | [.id, .client_name, .protocol, (.external_port|tostring), (.target_address // .client_address), (.client_port|tostring)] | @tsv' "$PORT_FORWARDS_JSON" | nl -ba | sed 's/\t/  /g'
    else
        echo "  (none)"
    fi
}

resolve_client_name() {
    local selection="$1"
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
        jq -r --argjson index "$selection" '.clients[$index - 1].name' "$CLIENTS_JSON"
    else
        echo "$selection"
    fi
}

resolve_forward_id() {
    local selection="$1"
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
        jq -r '.port_forwards[]? | select(.id != null) | .id' "$PORT_FORWARDS_JSON" | nl -ba | awk -v sel="$selection" '$1 == sel {print $2}'
    else
        echo "$selection"
    fi
}

valid_ipv4() {
    local address="$1"
    [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local octet
    IFS='.' read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
        [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
    done
}

ipv4_to_int() {
    local address="$1" a b c d
    IFS='.' read -r a b c d <<< "$address"
    echo $((10#$a * 16777216 + 10#$b * 65536 + 10#$c * 256 + 10#$d))
}

cidr_contains() {
    local cidr="$1" address="$2" network prefix mask network_int address_int
    [[ "$cidr" == */* ]] || return 1
    network="${cidr%/*}"
    prefix="${cidr#*/}"
    valid_ipv4 "$network" && valid_ipv4 "$address" || return 1
    [[ "$prefix" =~ ^[0-9]+$ ]] && [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ] || return 1
    network_int=$(ipv4_to_int "$network")
    address_int=$(ipv4_to_int "$address")
    if [ "$prefix" -eq 0 ]; then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi
    (( (network_int & mask) == (address_int & mask) ))
}

validate_target_address() {
    local client_name="$1" client_address="$2" target_address="$3" route
    valid_ipv4 "$target_address" || { echo "Invalid target IPv4 address: $target_address" >&2; return 1; }
    [ "$target_address" = "$client_address" ] && return 0
    while IFS= read -r route; do
        [ -n "$route" ] || continue
        if cidr_contains "$route" "$target_address"; then
            return 0
        fi
    done < <(jq -r --arg name "$client_name" '.clients[]? | select(.name == $name) | .routes[]?' "$CLIENTS_JSON")
    echo "Target $target_address is neither the VPN address of $client_name nor inside one of its client routes." >&2
    return 1
}

validate_port() {
    local label="$1" port="$2"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "$label must be between 1 and 65535." >&2
        return 1
    fi
}

add_forward() {
    local client_name="$1" protocol="$2" external_port="$3" client_port="$4" target_address="$5"
    local client_address
    if ! jq -e --arg name "$client_name" '.clients[]? | select(.name == $name)' "$CLIENTS_JSON" >/dev/null 2>&1; then
        echo "Client not found: $client_name" >&2
        return 1
    fi
    client_address=$(jq -r --arg name "$client_name" '.clients[]? | select(.name == $name) | .address' "$CLIENTS_JSON")
    [ -n "$client_address" ] && [ "$client_address" != null ] || { echo "Client has no address." >&2; return 1; }
    [ "$protocol" = tcp ] || [ "$protocol" = udp ] || { echo "Unsupported protocol: $protocol" >&2; return 1; }
    validate_port "External port" "$external_port"
    validate_port "Target port" "$client_port"
    [ -n "$target_address" ] || target_address="$client_address"
    validate_target_address "$client_name" "$client_address" "$target_address"

    if jq -e --arg protocol "$protocol" --argjson external_port "$external_port" '.port_forwards[]? | select(.id != null and .protocol == $protocol and .external_port == $external_port)' "$PORT_FORWARDS_JSON" >/dev/null 2>&1; then
        echo "External port already in use for protocol $protocol: $external_port" >&2
        return 1
    fi

    local id="${client_name}-${external_port}-${protocol}"
    if jq -e --arg id "$id" '.port_forwards[]? | select(.id == $id)' "$PORT_FORWARDS_JSON" >/dev/null 2>&1; then
        echo "Forward already exists: $id" >&2
        return 1
    fi

    local tmp
    tmp=$(mktemp)
    jq --arg id "$id" --arg client_name "$client_name" --arg client_address "$client_address" --arg target_address "$target_address" --argjson external_port "$external_port" --argjson client_port "$client_port" --arg protocol "$protocol" '.port_forwards += [{"id": $id, "client_name": $client_name, "client_address": $client_address, "target_address": $target_address, "external_port": $external_port, "client_port": $client_port, "protocol": $protocol, "enabled": true}]' "$PORT_FORWARDS_JSON" > "$tmp"
    mv "$tmp" "$PORT_FORWARDS_JSON"

    "$SCRIPT_DIR/internal/apply-port-forwards.sh"
    echo "Port forward added: $id ($protocol $external_port -> $target_address:$client_port)"
}

add_forward_interactive() {
    local selection client_name protocol external_port client_port target_address
    list_clients
    read -r -p "Select client number or name: " selection
    client_name=$(resolve_client_name "$selection")
    [ -n "$client_name" ] && [ "$client_name" != null ] || { echo "Invalid selection." >&2; return 1; }
    read -r -p "Protocol [tcp]: " protocol
    protocol=${protocol:-tcp}
    read -r -p "External port: " external_port
    read -r -p "Target port: " client_port
    read -r -p "Target IP (leave empty for the client VPN IP): " target_address
    add_forward "$client_name" "$protocol" "$external_port" "$client_port" "$target_address"
}

remove_forward() {
    local id="$1"
    if ! jq -e --arg id "$id" '.port_forwards[]? | select(.id == $id)' "$PORT_FORWARDS_JSON" >/dev/null 2>&1; then
        echo "Port forward not found: $id" >&2
        return 1
    fi
    local tmp
    tmp=$(mktemp)
    jq --arg id "$id" '.port_forwards |= map(select(.id != $id))' "$PORT_FORWARDS_JSON" > "$tmp"
    mv "$tmp" "$PORT_FORWARDS_JSON"
    "$SCRIPT_DIR/internal/apply-port-forwards.sh"
    echo "Port forward removed: $id"
}

remove_forward_interactive() {
    local selection id count
    list_forward_choices
    count=$(jq '[.port_forwards[]? | select(.id != null)] | length' "$PORT_FORWARDS_JSON")
    [ "$count" -gt 0 ] || return 0
    read -r -p "Select port forward number or ID to remove: " selection
    id=$(resolve_forward_id "$selection")
    [ -n "$id" ] && [ "$id" != null ] || { echo "Invalid selection." >&2; return 1; }
    remove_forward "$id"
}

interactive_menu() {
    local choice
    echo "WadVPN port-forward management"
    echo "  1) Add port forward"
    echo "  2) Remove port forward"
    echo "  3) List port forwards"
    echo "  4) Help"
    echo "  0) Exit"
    read -r -p "Select an action: " choice
    case "$choice" in
        1) add_forward_interactive ;;
        2) remove_forward_interactive ;;
        3) list_forwards ;;
        4) usage ;;
        0) ;;
        *) echo "Invalid selection." >&2; return 1 ;;
    esac
}

parse_add() {
    local client_name="" protocol="" external_port="" client_port="" target_address=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --protocol) [ $# -ge 2 ] || { echo "Missing value for --protocol" >&2; return 1; }; protocol="$2"; shift ;;
            --external-port) [ $# -ge 2 ] || { echo "Missing value for --external-port" >&2; return 1; }; external_port="$2"; shift ;;
            --target-port|--client-port) [ $# -ge 2 ] || { echo "Missing value for $1" >&2; return 1; }; client_port="$2"; shift ;;
            --target-address) [ $# -ge 2 ] || { echo "Missing value for --target-address" >&2; return 1; }; target_address="$2"; shift ;;
            --help|-h) usage; return 0 ;;
            -*) echo "Unknown option: $1" >&2; return 1 ;;
            *) [ -z "$client_name" ] || { echo "Unexpected argument: $1" >&2; return 1; }; client_name="$1" ;;
        esac
        shift
    done
    [ -n "$client_name" ] && [ -n "$protocol" ] && [ -n "$external_port" ] && [ -n "$client_port" ] || { echo "add requires <client>, --protocol, --external-port, and --target-port." >&2; return 1; }
    add_forward "$client_name" "$protocol" "$external_port" "$client_port" "$target_address"
}

main() {
    if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
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
        list) [ $# -eq 0 ] || { echo "list accepts no options." >&2; return 1; }; list_forwards ;;
        add) parse_add "$@" ;;
        remove)
            [ $# -eq 1 ] || { echo "remove requires one forward ID." >&2; return 1; }
            remove_forward "$1"
            ;;
        *) echo "Unknown command: $command" >&2; usage >&2; return 1 ;;
    esac
}

main "$@"
