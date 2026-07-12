#!/bin/bash

set -euo pipefail

INTERNAL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$INTERNAL_DIR/.." && pwd)"
# shellcheck source=../lib/config.sh
source "$SCRIPTS_DIR/lib/config.sh"
CONFIG="$PROJECT_DIR/config/routes.json"
CLIENTS_JSON="$PROJECT_DIR/config/clients.json"

apply_route() {
    local network="$1"
    local interface="$2"

    echo "Applying route: $network via $interface"
    ip route del "$network" dev "$interface" 2>/dev/null || true
    ip route replace "$network" dev "$interface"
}

jq -c '.routes[]' "$CONFIG" | while read -r route; do
    NETWORK=$(echo "$route" | jq -r '.network')
    INTERFACE=$(echo "$route" | jq -r '.interface')
    apply_route "$NETWORK" "$INTERFACE"
done

while IFS= read -r route; do
    [ -n "$route" ] || continue
    apply_route "$route" "$WADVPN_WG_INTERFACE"
done < <(jq -r '.clients[]? | select(.enabled == true) | .routes[]?' "$CLIENTS_JSON")
