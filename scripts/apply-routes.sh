#!/bin/bash

set -e

CONFIG="/opt/wad-vpn/config/routes.json"

jq -c '.routes[]' "$CONFIG" | while read -r route
do
    NETWORK=$(echo "$route" | jq -r '.network')
    INTERFACE=$(echo "$route" | jq -r '.interface')

    echo "Applying route: $NETWORK via $INTERFACE"

    ip route replace "$NETWORK" dev "$INTERFACE"
done
