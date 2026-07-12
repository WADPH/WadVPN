#!/bin/bash

set -euo pipefail

INTERNAL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$INTERNAL_DIR/.." && pwd)"
# shellcheck source=../lib/config.sh
source "$SCRIPTS_DIR/lib/config.sh"
CONFIG_PATH="$PROJECT_DIR/config/$WADVPN_WG_INTERFACE.conf"

if [ "$EUID" -ne 0 ]; then
    echo "Run this script as root."
    exit 1
fi

"$SCRIPTS_DIR/internal/generate-server-config.sh"

if ! wg-quick strip "$CONFIG_PATH" >/dev/null 2>&1; then
    echo "WireGuard configuration is invalid."
    exit 1
fi

mkdir -p /etc/wireguard
ln -sfn "$CONFIG_PATH" "/etc/wireguard/$WADVPN_WG_INTERFACE.conf"

if ip link show "$WADVPN_WG_INTERFACE" >/dev/null 2>&1; then
    wg-quick down "$WADVPN_WG_INTERFACE" >/dev/null 2>&1 || true
fi

if ! systemctl is-enabled "wg-quick@$WADVPN_WG_INTERFACE" >/dev/null 2>&1; then
    systemctl enable "wg-quick@$WADVPN_WG_INTERFACE" >/dev/null
fi

if systemctl is-active --quiet "wg-quick@$WADVPN_WG_INTERFACE"; then
    systemctl restart "wg-quick@$WADVPN_WG_INTERFACE" >/dev/null
else
    systemctl start "wg-quick@$WADVPN_WG_INTERFACE" >/dev/null
fi

"$SCRIPTS_DIR/internal/apply-firewall.sh"
"$SCRIPTS_DIR/internal/apply-routes.sh"
"$SCRIPTS_DIR/internal/apply-port-forwards.sh"

echo "WireGuard configuration applied."
