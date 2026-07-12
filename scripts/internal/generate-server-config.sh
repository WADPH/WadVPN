#!/bin/bash

set -euo pipefail

INTERNAL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$INTERNAL_DIR/.." && pwd)"
# shellcheck source=../lib/config.sh
source "$SCRIPTS_DIR/lib/config.sh"
CLIENTS_JSON="$PROJECT_DIR/config/clients.json"
SERVER_PRIVATE_KEY=$(cat "$PROJECT_DIR/config/keys/server_private.key")
OUTPUT="$PROJECT_DIR/config/$WADVPN_WG_INTERFACE.conf"

SERVER_ADDRESS="$WADVPN_WG_ADDRESS"
SERVER_PORT="$WADVPN_WG_LISTEN_PORT"

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
