#!/bin/bash

set -euo pipefail

PROJECT_DIR="/opt/wad-vpn"
CONFIG_PATH="$PROJECT_DIR/config/wg0.conf"

if [ "$EUID" -ne 0 ]; then
    echo "Run this script as root."
    exit 1
fi

"$PROJECT_DIR/scripts/generate-server-config.sh"

if ! wg-quick strip "$CONFIG_PATH" >/dev/null 2>&1; then
    echo "WireGuard configuration is invalid."
    exit 1
fi

mkdir -p /etc/wireguard
ln -sfn "$CONFIG_PATH" /etc/wireguard/wg0.conf

if ip link show wg0 >/dev/null 2>&1; then
    wg-quick down wg0 >/dev/null 2>&1 || true
fi

if ! systemctl is-enabled wg-quick@wg0 >/dev/null 2>&1; then
    systemctl enable wg-quick@wg0 >/dev/null
fi

if systemctl is-active --quiet wg-quick@wg0; then
    systemctl restart wg-quick@wg0 >/dev/null
else
    systemctl start wg-quick@wg0 >/dev/null
fi

"$PROJECT_DIR/scripts/apply-firewall.sh"
"$PROJECT_DIR/scripts/apply-routes.sh"
"$PROJECT_DIR/scripts/apply-port-forwards.sh"

echo "WireGuard configuration applied."
