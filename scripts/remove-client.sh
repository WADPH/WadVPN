#!/bin/bash

set -euo pipefail

PROJECT_DIR="/opt/wad-vpn"
CLIENTS_JSON="$PROJECT_DIR/config/clients.json"
CLIENTS_DIR="$PROJECT_DIR/clients"
CLIENT_CONFIGS_DIR="$PROJECT_DIR/generated/client-configs"
QR_DIR="$PROJECT_DIR/generated/qr"

usage() {
    echo "Usage:"
    echo "  remove-client.sh"
    echo "  remove-client.sh <client-name>"
    echo "  remove-client.sh <client-name> --force"
    exit 1
}

if [ "$EUID" -ne 0 ]; then
    echo "Run this script as root."
    exit 1
fi

FORCE=false
POSITIONAL=()

while [ $# -gt 0 ]; do
    case "$1" in
        --force)
            FORCE=true
            ;;
        --help|-h)
            usage
            ;;
        -*)
            echo "Unknown option: $1"
            usage
            ;;
        *)
            POSITIONAL+=("$1")
            ;;
    esac
    shift
done

if [ ${#POSITIONAL[@]} -gt 1 ]; then
    usage
fi

if [ ${#POSITIONAL[@]} -eq 1 ]; then
    CLIENT_NAME="${POSITIONAL[0]}"
else
    CLIENT_NAME=""
fi

show_clients() {
    echo "Available clients:"
    echo "  #  Name         Enabled  Protected  Isolated"
    local idx=1
    while IFS=$'\t' read -r name enabled protected isolated; do
        if [ "$enabled" = "true" ]; then
            enabled="yes"
        else
            enabled="no"
        fi
        if [ "$protected" = "true" ]; then
            protected="yes"
        else
            protected="no"
        fi
        if [ "$isolated" = "true" ]; then
            isolated="yes"
        else
            isolated="no"
        fi
        printf '  %2s  %-12s  %-8s  %-10s  %s\n' "$idx" "$name" "$enabled" "$protected" "$isolated"
        idx=$((idx + 1))
    done < <(jq -r '.clients[] | [.name, ((.enabled // true)|tostring), ((.protected // false)|tostring), ((.isolated // false)|tostring)] | @tsv' "$CLIENTS_JSON")
}

resolve_client_name() {
    local selection="$1"
    jq -r --argjson index "$selection" '.clients[$index - 1].name' "$CLIENTS_JSON"
}

if [ -z "$CLIENT_NAME" ]; then
    show_clients
    echo
    read -r -p "Select client number to remove: " selection
    if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
        echo "Invalid selection."
        exit 1
    fi
    CLIENT_NAME=$(resolve_client_name "$selection")
    if [ "$CLIENT_NAME" = "null" ]; then
        echo "Invalid selection."
        exit 1
    fi
fi

if ! jq -e --arg name "$CLIENT_NAME" '.clients[]? | select(.name == $name)' "$CLIENTS_JSON" >/dev/null 2>&1; then
    echo "Client not found."
    exit 1
fi

if [ "$(jq -r --arg name "$CLIENT_NAME" '.clients[]? | select(.name == $name) | (.protected // false)' "$CLIENTS_JSON")" = "true" ]; then
    if [ "$FORCE" != true ]; then
        echo "Protected client cannot be removed: $CLIENT_NAME"
        echo "Use --force to remove it anyway."
        exit 1
    fi
fi

read -r -p "Remove client '$CLIENT_NAME'? [y/N] " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "Aborted."
    exit 0
fi

while IFS= read -r route; do
    [ -n "$route" ] || continue
    ip route del "$route" dev wg0 2>/dev/null || true
done < <(jq -r --arg name "$CLIENT_NAME" '.clients[]? | select(.name == $name) | .routes[]?' "$CLIENTS_JSON")

TMP=$(mktemp)
jq --arg name "$CLIENT_NAME" '.clients |= map(select(.name != $name))' "$CLIENTS_JSON" > "$TMP"
mv "$TMP" "$CLIENTS_JSON"

rm -rf "$CLIENTS_DIR/$CLIENT_NAME"
rm -f "$CLIENT_CONFIGS_DIR/$CLIENT_NAME.conf"
rm -f "$QR_DIR/$CLIENT_NAME.png"

PORT_FORWARDS_JSON="$PROJECT_DIR/config/port-forwards.json"
if [ -f "$PORT_FORWARDS_JSON" ]; then
    REMOVED_FORWARDS=$(jq -c --arg name "$CLIENT_NAME" '[.port_forwards[]? | select(.client_name == $name)]' "$PORT_FORWARDS_JSON")
    if [ "$REMOVED_FORWARDS" != "[]" ]; then
        TMP=$(mktemp)
        jq --arg name "$CLIENT_NAME" '.port_forwards |= map(select(.client_name != $name))' "$PORT_FORWARDS_JSON" > "$TMP"
        mv "$TMP" "$PORT_FORWARDS_JSON"
        echo "Removed port forwards for client '$CLIENT_NAME':"
        echo "$REMOVED_FORWARDS" | jq -r '.[] | "  - \(.id) \(.protocol) \(.external_port) -> \(.client_address):\(.client_port)"'
    fi
fi

"$PROJECT_DIR/scripts/apply-wireguard.sh"
"$PROJECT_DIR/scripts/apply-port-forwards.sh"

echo "Client removed: $CLIENT_NAME"
