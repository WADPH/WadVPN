#!/bin/bash

set -euo pipefail

PROJECT_DIR="/opt/wad-vpn"
CLIENTS_DIR="$PROJECT_DIR/clients"
CONFIG_DIR="$PROJECT_DIR/config"
GENERATED_DIR="$PROJECT_DIR/generated"
CLIENT_CONFIGS_DIR="$GENERATED_DIR/client-configs"
QR_DIR="$GENERATED_DIR/qr"
CLIENTS_JSON="$CONFIG_DIR/clients.json"
SETTINGS_JSON="$CONFIG_DIR/settings.json"

usage() {
    echo "Usage:"
    echo "create-client.sh <client-name> [--protected] [--isolated] [--route <network>]... [--ip <address>]"
    exit 1
}

if [ "$EUID" -ne 0 ]; then
    echo "Run as root."
    exit 1
fi

PROTECTED=false
ISOLATED=false
ROUTES=()
CLIENT_NAME=""
CLIENT_ADDRESS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --protected)
            PROTECTED=true
            ;;
        --isolated)
            ISOLATED=true
            ;;
        --route)
            [ $# -ge 2 ] || { echo "Missing value for --route"; exit 1; }
            ROUTES+=("$2")
            shift
            ;;
        --ip)
            [ $# -ge 2 ] || { echo "Missing value for --ip"; exit 1; }
            CLIENT_ADDRESS="$2"
            shift
            ;;
        --help|-h)
            usage
            ;;
        -*)
            echo "Unknown option: $1"
            usage
            ;;
        *)
            if [ -n "$CLIENT_NAME" ]; then
                echo "Unexpected argument: $1"
                usage
            fi
            CLIENT_NAME="$1"
            ;;
    esac
    shift
done

[ -n "$CLIENT_NAME" ] || usage

CLIENT_DIR="$CLIENTS_DIR/$CLIENT_NAME"

if jq -e --arg name "$CLIENT_NAME" '.clients[]? | select(.name == $name)' "$CLIENTS_JSON" >/dev/null 2>&1; then
    echo "Client already exists."
    exit 1
fi

SERVER_NETWORK=$(jq -r '.vpn.network' "$SETTINGS_JSON")
VPN_PREFIX=$(echo "$SERVER_NETWORK" | awk -F. '{print $1"."$2"."$3}')
CIDR=$(echo "$SERVER_NETWORK" | awk -F/ '{print $2}')

if [ -z "$CLIENT_ADDRESS" ]; then
    USED_IPS=$(jq -r '.clients[]?.address // empty' "$CLIENTS_JSON" | awk -F. '{print $4}' | sort -n)
    NEXT_IP=2
    while echo "$USED_IPS" | grep -q "^$NEXT_IP$"; do
        NEXT_IP=$((NEXT_IP + 1))
    done
    CLIENT_ADDRESS="$VPN_PREFIX.$NEXT_IP"
else
    if ! echo "$CLIENT_ADDRESS" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
        echo "Invalid IP address: $CLIENT_ADDRESS"
        exit 1
    fi
    if jq -e --arg addr "$CLIENT_ADDRESS" '.clients[]? | select(.address == $addr)' "$CLIENTS_JSON" >/dev/null 2>&1; then
        echo "IP address already in use: $CLIENT_ADDRESS"
        exit 1
    fi
fi
ROUTES_JSON=$(printf '%s\n' "${ROUTES[@]}" | jq -R . | jq -s -c '.')

mkdir -p "$CLIENT_DIR" "$CLIENT_CONFIGS_DIR" "$QR_DIR"

umask 077
wg genkey | tee "$CLIENT_DIR/private.key" | wg pubkey > "$CLIENT_DIR/public.key"
chmod 600 "$CLIENT_DIR/private.key" "$CLIENT_DIR/public.key"

PUBLIC_KEY=$(cat "$CLIENT_DIR/public.key")
SERVER_PUBLIC_KEY=$(cat "$CONFIG_DIR/keys/server_public.key")
SERVER_HOST=$(jq -r '.server.public_hostname // .server.public_ip' "$SETTINGS_JSON")
SERVER_PORT=$(jq -r '.wireguard.listen_port' "$SETTINGS_JSON")
DNS_SERVER=$(jq -r '.vpn.dns[0]' "$SETTINGS_JSON")

TMP=$(mktemp)
jq \
--arg name "$CLIENT_NAME" \
--arg addr "$CLIENT_ADDRESS" \
--arg key "$PUBLIC_KEY" \
--argjson protected "$PROTECTED" \
--argjson isolated "$ISOLATED" \
--argjson routes "$ROUTES_JSON" \
'.clients += [{
    "name": $name,
    "enabled": true,
    "address": $addr,
    "public_key": $key,
    "protected": $protected,
    "isolated": $isolated,
    "routes": $routes,
    "groups": []
}]' \
"$CLIENTS_JSON" > "$TMP"
mv "$TMP" "$CLIENTS_JSON"

"$PROJECT_DIR/scripts/apply-wireguard.sh"

CLIENT_CONFIG_PATH="$CLIENT_CONFIGS_DIR/$CLIENT_NAME.conf"
cat > "$CLIENT_CONFIG_PATH" <<EOF_CONFIG
[Interface]
PrivateKey = $(cat "$CLIENT_DIR/private.key")
Address = $CLIENT_ADDRESS/$CIDR
DNS = $DNS_SERVER

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_HOST:$SERVER_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF_CONFIG

QR_PATH="$QR_DIR/$CLIENT_NAME.png"
qrencode -t PNG -o "$QR_PATH" < "$CLIENT_CONFIG_PATH"

echo
echo "Client created successfully."
echo
echo "Name       : $CLIENT_NAME"
echo "IP         : $CLIENT_ADDRESS"
echo "Protected  : $PROTECTED"
echo "Isolated   : $ISOLATED"
echo "Routes     : ${ROUTES[*]:-none}"
echo "Config     : $CLIENT_CONFIG_PATH"
echo "QR PNG     : $QR_PATH"
echo
echo "To view the client config:"
echo "  cat $CLIENT_CONFIG_PATH"
echo "To download the config from the server:"
echo "  scp root@$(hostname -I | awk '{print $1}'):$CLIENT_CONFIG_PATH ./"
echo "To view the QR in terminal:"
echo "  qrencode -t ANSIUTF8 < $CLIENT_CONFIG_PATH"
echo
echo "ASCII QR:"
qrencode -t ANSIUTF8 "$CLIENT_CONFIG_PATH"
