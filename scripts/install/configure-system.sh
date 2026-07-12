#!/bin/bash

set -euo pipefail

echo "[2/4] Configuring system..."

cat >/etc/sysctl.d/99-wadvpn.conf <<EOF
net.ipv4.ip_forward=1
EOF

sysctl --system >/dev/null
