#!/bin/bash

set -euo pipefail

PROJECT_DIR="/opt/wad-vpn"

CLIENTS_JSON="$PROJECT_DIR/config/clients.json"
SETTINGS_JSON="$PROJECT_DIR/config/settings.json"

SERVER_PRIVATE_KEY=$(cat "$PROJECT_DIR/config/keys/server_private.key")

OUTPUT="$PROJECT_DIR/config/wg0.conf"

SERVER_ADDRESS=$(jq -r '.wireguard.address' "$SETTINGS_JSON")
SERVER_PORT=$(jq -r '.wireguard.listen_port' "$SETTINGS_JSON")

cat > "$OUTPUT" <<EOF
[Interface]
Address = $SERVER_ADDRESS
ListenPort = $SERVER_PORT
PrivateKey = $SERVER_PRIVATE_KEY

EOF

jq -c '.clients[] | select(.enabled == true)' "$CLIENTS_JSON" | while read -r CLIENT
do
    PUBLIC_KEY=$(echo "$CLIENT" | jq -r '.public_key')
    ADDRESS=$(echo "$CLIENT" | jq -r '.address')

    ROUTES=$(echo "$CLIENT" | jq -r '.routes[]?' | paste -sd "," -)

    if [ -n "$ROUTES" ]; then
        ALLOWED_IPS="$ADDRESS/32,$ROUTES"
    else
        ALLOWED_IPS="$ADDRESS/32"
    fi

cat >> "$OUTPUT" <<EOF
[Peer]
PublicKey = $PUBLIC_KEY
AllowedIPs = $ALLOWED_IPS

EOF

done

echo "Generated $OUTPUT"
