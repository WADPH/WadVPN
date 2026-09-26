#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
FAILURES=0

print_ok() {
    echo "[OK] $1"
}

print_fail() {
    echo "[FAIL] $1"
    FAILURES=1
}

check_wireguard() {
    if systemctl is-active --quiet "wg-quick@$WADVPN_WG_INTERFACE"; then
        print_ok "WireGuard service is active"
    else
        print_fail "WireGuard service is not active"
    fi

    if ip link show "$WADVPN_WG_INTERFACE" >/dev/null 2>&1; then
        print_ok "WireGuard interface $WADVPN_WG_INTERFACE exists"
    else
        print_fail "WireGuard interface $WADVPN_WG_INTERFACE is missing"
    fi

    if systemctl is-enabled --quiet wadvpn-firewall.service 2>/dev/null; then
        print_ok "Firewall is restored at boot (wadvpn-firewall.service)"
    else
        print_fail "wadvpn-firewall.service is not enabled; rules are lost on reboot"
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
        if [ -n "$(ip route show "$route" 2>/dev/null)" ]; then
            print_ok "Route present: $route"
        else
            print_fail "Route missing: $route"
        fi
    done <<< "$expected"
}

check_firewall() {
    local interface="$WADVPN_WAN_INTERFACE"

    if iptables -C FORWARD -i "$WADVPN_WG_INTERFACE" -j ACCEPT >/dev/null 2>&1; then
        print_ok "Forward rule for $WADVPN_WG_INTERFACE exists"
    else
        print_fail "Forward rule for $WADVPN_WG_INTERFACE is missing"
    fi

    if [ "$(iptables -S FORWARD | grep -m1 '^-A ')" = "-A FORWARD -i $WADVPN_WG_INTERFACE -o $WADVPN_WG_INTERFACE -j WADVPN-C2C" ]; then
        print_ok "Client-to-client traffic is filtered by group (WADVPN-C2C)"
    else
        print_fail "Group filter WADVPN-C2C is not the first FORWARD rule"
    fi

    local group
    while IFS= read -r group; do
        if ipset list -n 2>/dev/null | grep -qx "wadvpn-g-$group"; then
            print_ok "Group set exists: $group"
        else
            print_fail "Group set is missing: $group"
        fi
    done < <(jq -r '.groups[]?' "$PROJECT_DIR/config/clients.json")

    if iptables -t nat -C POSTROUTING -s "$WADVPN_VPN_NETWORK" -o "$interface" -j MASQUERADE >/dev/null 2>&1; then
        print_ok "MASQUERADE rule exists"
    else
        print_fail "MASQUERADE rule is missing"
    fi
}

check_config() {
    if [ -f "$PROJECT_DIR/config/$WADVPN_WG_INTERFACE.conf" ]; then
        print_ok "Server config exists"
    else
        print_fail "Server config is missing"
        return
    fi

    if wg-quick strip "$PROJECT_DIR/config/$WADVPN_WG_INTERFACE.conf" >/dev/null 2>&1; then
        print_ok "Server config is syntactically valid"
    else
        print_fail "Server config validation failed"
    fi
}

echo "[4/4] Verifying installation..."
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
