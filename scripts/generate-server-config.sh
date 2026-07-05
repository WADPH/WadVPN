#!/bin/bash

set -euo pipefail

PROJECT_DIR="/opt/wad-vpn"
CLIENTS_JSON="$PROJECT_DIR/config/clients.json"
SETTINGS_JSON="$PROJECT_DIR/config/settings.json"
SERVER_PRIVATE_KEY=$(cat "$PROJECT_DIR/config/keys/server_private.key")
OUTPUT="$PROJECT_DIR/config/wg0.conf"

SERVER_ADDRESS=$(jq -r '.wireguard.address' "$SETTINGS_JSON")
SERVER_PORT=$(jq -r '.wireguard.listen_port' "$SETTINGS_JSON")

cat > "$OUTPUT" <<EOF_CONF
[Interface]
Address = $SERVER_ADDRESS
ListenPort = $SERVER_PORT
PrivateKey = $SERVER_PRIVATE_KEY

EOF_CONF

while IFS= read -r client; do
    PUBLIC_KEY=$(echo "$client" | jq -r '.public_key')
    ADDRESS=$(echo "$client" | jq -r '.address')
    ROUTES=$(echo "$client" | jq -r '.routes[]?' | paste -sd "," -)

    if [ -n "$ROUTES" ]; then
        ALLOWED_IPS="$ADDRESS/32,$ROUTES"
    else
        ALLOWED_IPS="$ADDRESS/32"
    fi

    cat >> "$OUTPUT" <<EOF_PEER
[Peer]
PublicKey = $PUBLIC_KEY
AllowedIPs = $ALLOWED_IPS

EOF_PEER
done < <(jq -c '.clients[] | select(.enabled == true)' "$CLIENTS_JSON")

echo "Generated $OUTPUT"
