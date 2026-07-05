#!/bin/bash

set -euo pipefail

echo "[5/5] Verifying installation..."

systemctl is-active --quiet wg-quick@wg0 || {
    echo "WireGuard is not running."
    exit 1
}

ip link show wg0 >/dev/null

ip route show | grep -q "10.200.0.0/24" || {
    echo "WireGuard route missing."
    exit 1
}

sysctl net.ipv4.ip_forward | grep -q "= 1" || {
    echo "IPv4 forwarding disabled."
    exit 1
}

echo "Verification successful."
