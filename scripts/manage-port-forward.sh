#!/bin/bash

set -euo pipefail

PROJECT_DIR="/opt/wad-vpn"
CONFIG_DIR="$PROJECT_DIR/config"
CLIENTS_JSON="$CONFIG_DIR/clients.json"
PORT_FORWARDS_JSON="$CONFIG_DIR/port-forwards.json"

usage() {
    echo "Usage:"
    echo "  manage-port-forward.sh list"
    echo "  manage-port-forward.sh add [client-name]"
    echo "  manage-port-forward.sh remove [id]"
    exit 1
}

if [ "$EUID" -ne 0 ]; then
    echo "Run this script as root."
    exit 1
fi

cmd="${1:-}"
if [ -n "$cmd" ]; then
    shift || true
fi

list_clients() {
    echo "Available clients:"
    jq -r '.clients[]? | [.name, .address, ((.enabled // true)|tostring)] | @tsv' "$CLIENTS_JSON" | nl -ba | sed 's/\t/  /g'
}

list_forwards() {
    echo "Active port forwards:"
    local count
    count=$(jq '[.port_forwards[]? | select(.id != null)] | length' "$PORT_FORWARDS_JSON")
    if [ "$count" -gt 0 ]; then
        jq -r '.port_forwards[]? | select(.id != null) | ["ID=\(.id)", "Client=\(.client_name)", "Proto=\(.protocol)", "External=\(.external_port)", "Target=\(.client_address):\(.client_port)"] | @tsv' "$PORT_FORWARDS_JSON"
    else
        echo "  (none)"
    fi
}

list_forward_choices() {
    echo "Available port forwards:"
    local count
    count=$(jq '[.port_forwards[]? | select(.id != null)] | length' "$PORT_FORWARDS_JSON")
    if [ "$count" -gt 0 ]; then
        jq -r '.port_forwards[]? | select(.id != null) | [.id, .client_name, .protocol, (.external_port|tostring), .client_address, (.client_port|tostring)] | @tsv' "$PORT_FORWARDS_JSON" | nl -ba | sed 's/\t/  /g'
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

add_forward() {
    local client_name="${1:-}"
    if [ -z "$client_name" ]; then
        list_clients
        echo
        read -r -p "Select client number or name: " selection
        client_name=$(resolve_client_name "$selection")
    fi

    if ! jq -e --arg name "$client_name" '.clients[]? | select(.name == $name)' "$CLIENTS_JSON" >/dev/null 2>&1; then
        echo "Client not found: $client_name"
        exit 1
    fi

    local client_address
    client_address=$(jq -r --arg name "$client_name" '.clients[]? | select(.name == $name) | .address' "$CLIENTS_JSON")
    [ -n "$client_address" ] || { echo "Client has no address."; exit 1; }

    read -r -p "Protocol [tcp]: " protocol
    protocol=${protocol:-tcp}
    if [ "$protocol" != "tcp" ] && [ "$protocol" != "udp" ]; then
        echo "Unsupported protocol: $protocol"
        exit 1
    fi

    read -r -p "External port: " external_port
    read -r -p "Client port: " client_port

    if ! [[ "$external_port" =~ ^[0-9]+$ ]] || ! [[ "$client_port" =~ ^[0-9]+$ ]]; then
        echo "Ports must be numeric."
        exit 1
    fi

    if [ "$external_port" -lt 1 ] || [ "$external_port" -gt 65535 ] || [ "$client_port" -lt 1 ] || [ "$client_port" -gt 65535 ]; then
        echo "Ports must be between 1 and 65535."
        exit 1
    fi

    if jq -e --arg protocol "$protocol" --argjson external_port "$external_port" '.port_forwards[]? | select(.id != null and .protocol == $protocol and .external_port == $external_port)' "$PORT_FORWARDS_JSON" >/dev/null 2>&1; then
        echo "External port already in use for protocol $protocol: $external_port"
        exit 1
    fi

    local id="${client_name}-${external_port}-${protocol}"
    if jq -e --arg id "$id" '.port_forwards[]? | select(.id == $id)' "$PORT_FORWARDS_JSON" >/dev/null 2>&1; then
        echo "Forward already exists: $id"
        exit 1
    fi

    local tmp
    tmp=$(mktemp)
    jq --arg id "$id" --arg client_name "$client_name" --arg client_address "$client_address" --argjson external_port "$external_port" --argjson client_port "$client_port" --arg protocol "$protocol" '.port_forwards += [{"id": $id, "client_name": $client_name, "client_address": $client_address, "external_port": $external_port, "client_port": $client_port, "protocol": $protocol, "enabled": true}]' "$PORT_FORWARDS_JSON" > "$tmp"
    mv "$tmp" "$PORT_FORWARDS_JSON"

    "$PROJECT_DIR/scripts/apply-port-forwards.sh"
    echo "Port forward added: $id"
}

resolve_forward_id() {
    local selection="$1"
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
        jq -r '.port_forwards[]? | select(.id != null) | .id' "$PORT_FORWARDS_JSON" | nl -ba | awk -v sel="$selection" '$1 == sel {print $2}'
    else
        echo "$selection"
    fi
}

remove_forward() {
    local id="${1:-}"
    if [ -z "$id" ]; then
        list_forward_choices
        echo
        local count
        count=$(jq '[.port_forwards[]? | select(.id != null)] | length' "$PORT_FORWARDS_JSON")
        if [ "$count" -eq 0 ]; then
            echo "No active port forwards to remove."
            exit 0
        fi
        read -r -p "Select port forward number to remove: " selection
        if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
            echo "Invalid selection."
            exit 1
        fi
        id=$(resolve_forward_id "$selection")
        if [ -z "$id" ] || [ "$id" = "null" ]; then
            echo "Invalid selection."
            exit 1
        fi
    fi

    local tmp
    tmp=$(mktemp)
    jq --arg id "$id" '.port_forwards |= map(select(.id != $id))' "$PORT_FORWARDS_JSON" > "$tmp"
    mv "$tmp" "$PORT_FORWARDS_JSON"

    "$PROJECT_DIR/scripts/apply-port-forwards.sh"
    echo "Port forward removed: $id"
}

case "$cmd" in
    "")
        usage
        ;;
    list)
        list_forwards
        ;;
    add)
        add_forward "${1:-}"
        ;;
    remove)
        remove_forward "${1:-}"
        ;;
    *)
        usage
        ;;
esac
