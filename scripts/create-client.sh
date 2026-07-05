#!/bin/bash

set -euo pipefail

PROJECT_DIR="/opt/wad-vpn"

CLIENTS_DIR="$PROJECT_DIR/clients"
CONFIG_DIR="$PROJECT_DIR/config"

CLIENTS_JSON="$CONFIG_DIR/clients.json"

VPN_PREFIX="10.200.0"

usage() {
    echo "Usage:"
    echo "create-client.sh <client-name>"
    exit 1
}

if [ "$EUID" -ne 0 ]; then
    echo "Run as root."
    exit 1
fi

[ $# -eq 1 ] || usage

CLIENT_NAME="$1"

CLIENT_DIR="$CLIENTS_DIR/$CLIENT_NAME"

if [ -d "$CLIENT_DIR" ]; then
    echo "Client already exists."
    exit 1
fi

NEXT_IP=$(jq -r '.clients[].address' "$CLIENTS_JSON" \
    | awk -F. '{print $4}' \
    | sort -n \
    | tail -1)

NEXT_IP=$((NEXT_IP + 1))

CLIENT_ADDRESS="$VPN_PREFIX.$NEXT_IP"

mkdir -p "$CLIENT_DIR"

wg genkey > "$CLIENT_DIR/private.key"
wg pubkey < "$CLIENT_DIR/private.key" > "$CLIENT_DIR/public.key"

PUBLIC_KEY=$(cat "$CLIENT_DIR/public.key")

TMP=$(mktemp)

jq \
--arg name "$CLIENT_NAME" \
--arg addr "$CLIENT_ADDRESS" \
--arg key "$PUBLIC_KEY" \
'.clients += [{
    "name": $name,
    "enabled": true,
    "address": $addr,
    "public_key": $key,
    "routes": []
}]' \
"$CLIENTS_JSON" > "$TMP"

mv "$TMP" "$CLIENTS_JSON"

echo
echo "Client created successfully."
echo
echo "Name : $CLIENT_NAME"
echo "IP   : $CLIENT_ADDRESS"
