#!/bin/bash

set -euo pipefail

PROJECT_DIR="/opt/wad-vpn"
FAILURES=0

print_ok() {
    echo "[OK] $1"
}

print_fail() {
    echo "[FAIL] $1"
    FAILURES=1
}

check_wireguard() {
    if systemctl is-active --quiet wg-quick@wg0; then
        print_ok "WireGuard service is active"
    else
        print_fail "WireGuard service is not active"
    fi

    if ip link show wg0 >/dev/null 2>&1; then
        print_ok "WireGuard interface wg0 exists"
    else
        print_fail "WireGuard interface wg0 is missing"
    fi
}

check_forwarding() {
    local current
    current=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)
    if [ "$current" = "1" ]; then
        print_ok "IPv4 forwarding is enabled"
    else
        print_fail "IPv4 forwarding is disabled"
    fi
}

check_routes() {
    local expected
    expected=$(jq -r '.routes[].network' "$PROJECT_DIR/config/routes.json")
    if [ -z "$expected" ]; then
        print_ok "No additional routes are configured"
        return
    fi

    while IFS= read -r route; do
        if ip route show "$route" >/dev/null 2>&1; then
            print_ok "Route present: $route"
        else
            print_fail "Route missing: $route"
        fi
    done <<< "$expected"
}

check_firewall() {
    local interface
    interface=$(jq -r '.server.interface // "ens3"' "$PROJECT_DIR/config/settings.json")

    if iptables -C FORWARD -i wg0 -j ACCEPT >/dev/null 2>&1; then
        print_ok "Forward rule for wg0 exists"
    else
        print_fail "Forward rule for wg0 is missing"
    fi

    if iptables -t nat -C POSTROUTING -s 10.200.0.0/24 -o "$interface" -j MASQUERADE >/dev/null 2>&1; then
        print_ok "MASQUERADE rule exists"
    else
        print_fail "MASQUERADE rule is missing"
    fi
}

check_config() {
    if [ -f "$PROJECT_DIR/config/wg0.conf" ]; then
        print_ok "Server config exists"
    else
        print_fail "Server config is missing"
        return
    fi

    if wg-quick strip "$PROJECT_DIR/config/wg0.conf" >/dev/null 2>&1; then
        print_ok "Server config is syntactically valid"
    else
        print_fail "Server config validation failed"
    fi
}

echo "[5/5] Verifying installation..."
check_wireguard
check_forwarding
check_routes
check_firewall
check_config

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "Verification successful."
else
    echo "Verification completed with errors."
    exit 1
fi
