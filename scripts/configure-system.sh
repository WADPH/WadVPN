#!/bin/bash

set -euo pipefail

PROJECT_DIR="/opt/wad-vpn"

echo "[2/5] Configuring system..."

mkdir -p /etc/wireguard

ln -sfn \
"$PROJECT_DIR/config/wg0.conf" \
/etc/wireguard/wg0.conf

cat >/etc/sysctl.d/99-wadvpn.conf <<EOF
net.ipv4.ip_forward=1
EOF

sysctl --system >/dev/null

systemctl enable wg-quick@wg0 >/dev/null

if ! systemctl is-active --quiet wg-quick@wg0; then
    systemctl start wg-quick@wg0
fi
