#!/bin/bash

set -euo pipefail

INTERNAL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$INTERNAL_DIR/.." && pwd)"
# shellcheck source=../lib/config.sh
source "$SCRIPTS_DIR/lib/config.sh"
CONFIG_DIR="$PROJECT_DIR/config"
PORT_FORWARDS_JSON="$CONFIG_DIR/port-forwards.json"

if [ "$EUID" -ne 0 ]; then
    echo "Run this script as root."
    exit 1
fi

INTERFACE="$WADVPN_WAN_INTERFACE"
WG_INTERFACE="$WADVPN_WG_INTERFACE"

clear_existing_forward_rules() {
    local table="$1"
    local output
    if [ "$table" = "nat" ]; then
        output=$(iptables -t nat -S 2>/dev/null || true)
    else
        output=$(iptables -S 2>/dev/null || true)
    fi

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if echo "$line" | grep -Eq -- '--comment [^ ]+'; then
            local comment
            comment=$(echo "$line" | sed -nE 's/.*--comment ([^ ]+).*/\1/p')
            if [[ "$comment" =~ ^[A-Za-z0-9._-]+-[0-9]+-(tcp|udp)$ ]]; then
                local parts=()
                read -r -a parts <<< "$line"
                if [ ${#parts[@]} -lt 2 ]; then
                    continue
                fi
                parts[0]='-D'
                if [ "$table" = "nat" ]; then
                    iptables -t nat "${parts[@]}" 2>/dev/null || true
                else
                    iptables "${parts[@]}" 2>/dev/null || true
                fi
            fi
        fi
    done <<< "$output"
}

add_forward_rules() {
    local id="$1"
    local target_address="$2"
    local client_port="$3"
    local external_port="$4"
    local protocol="$5"

    if ! iptables -t nat -C PREROUTING -i "$INTERFACE" -p "$protocol" --dport "$external_port" -j DNAT --to-destination "$target_address:$client_port" -m comment --comment "$id" >/dev/null 2>&1; then
        iptables -t nat -A PREROUTING -i "$INTERFACE" -p "$protocol" --dport "$external_port" -j DNAT --to-destination "$target_address:$client_port" -m comment --comment "$id"
    fi

    if ! iptables -C INPUT -i "$INTERFACE" -p "$protocol" --dport "$external_port" -j ACCEPT -m comment --comment "$id" >/dev/null 2>&1; then
        iptables -I INPUT 1 -i "$INTERFACE" -p "$protocol" --dport "$external_port" -j ACCEPT -m comment --comment "$id"
    fi

    if ! iptables -C FORWARD -i "$INTERFACE" -o "$WG_INTERFACE" -p "$protocol" -d "$target_address" --dport "$client_port" -j ACCEPT -m comment --comment "$id" >/dev/null 2>&1; then
        iptables -A FORWARD -i "$INTERFACE" -o "$WG_INTERFACE" -p "$protocol" -d "$target_address" --dport "$client_port" -j ACCEPT -m comment --comment "$id"
    fi
}

remove_forward_rules() {
    local id="$1"
    local target_address="$2"
    local client_port="$3"
    local external_port="$4"
    local protocol="$5"

    iptables -t nat -D PREROUTING -i "$INTERFACE" -p "$protocol" --dport "$external_port" -j DNAT --to-destination "$target_address:$client_port" -m comment --comment "$id" 2>/dev/null || true
    iptables -D INPUT -i "$INTERFACE" -p "$protocol" --dport "$external_port" -j ACCEPT -m comment --comment "$id" 2>/dev/null || true
    iptables -D FORWARD -i "$INTERFACE" -o "$WG_INTERFACE" -p "$protocol" -d "$target_address" --dport "$client_port" -j ACCEPT -m comment --comment "$id" 2>/dev/null || true
}

main() {
    if [ ! -f "$PORT_FORWARDS_JSON" ]; then
        echo "Port forwards config not found: $PORT_FORWARDS_JSON"
        exit 1
    fi

    clear_existing_forward_rules nat
    clear_existing_forward_rules filter

    if jq -e '.port_forwards[]? | select(.id != null)' "$PORT_FORWARDS_JSON" >/dev/null 2>&1; then
        local duplicates
        duplicates=$(jq -r '.port_forwards[]? | select(.id != null) | [.protocol, (.external_port|tostring)] | @tsv' "$PORT_FORWARDS_JSON" | sort | uniq -d || true)
        if [ -n "$duplicates" ]; then
            echo "Duplicate port-forward definitions detected:"
            echo "$duplicates"
            exit 1
        fi
    fi

    while IFS=$'\t' read -r id target_address client_port external_port protocol; do
        [ -n "$id" ] || continue
        remove_forward_rules "$id" "$target_address" "$client_port" "$external_port" "$protocol"
    done < <(jq -r '.port_forwards[]? | [.id, (.target_address // .client_address), (.client_port|tostring), (.external_port|tostring), .protocol] | @tsv' "$PORT_FORWARDS_JSON")

    while IFS=$'\t' read -r id target_address client_port external_port protocol; do
        [ -n "$id" ] || continue
        add_forward_rules "$id" "$target_address" "$client_port" "$external_port" "$protocol"
    done < <(jq -r '.port_forwards[]? | select(.id != null) | [.id, (.target_address // .client_address), (.client_port|tostring), (.external_port|tostring), .protocol] | @tsv' "$PORT_FORWARDS_JSON")
}

main "$@"
