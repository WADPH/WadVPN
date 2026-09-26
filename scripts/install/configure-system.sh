#!/bin/bash

set -euo pipefail

INSTALL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$INSTALL_DIR/.." && pwd)"
# shellcheck source=../lib/config.sh
source "$SCRIPTS_DIR/lib/config.sh"

echo "[2/4] Configuring system..."

cat >/etc/sysctl.d/99-wadvpn.conf <<EOF_SYSCTL
net.ipv4.ip_forward=1
EOF_SYSCTL

sysctl --system >/dev/null

# iptables rules and ipsets do not survive a reboot.  This unit restores them
# before WireGuard starts, and WireGuard does not start when it fails, so
# clients are never connected without the group filter.
cat >/etc/systemd/system/wadvpn-firewall.service <<EOF_UNIT
[Unit]
Description=WadVPN firewall, client groups, and port forwards
Before=wg-quick@$WADVPN_WG_INTERFACE.service
Wants=network-pre.target
After=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart="$SCRIPTS_DIR/internal/apply-firewall.sh"
ExecStart="$SCRIPTS_DIR/internal/apply-port-forwards.sh"

[Install]
WantedBy=multi-user.target
RequiredBy=wg-quick@$WADVPN_WG_INTERFACE.service
EOF_UNIT

systemctl daemon-reload
systemctl enable wadvpn-firewall.service >/dev/null
