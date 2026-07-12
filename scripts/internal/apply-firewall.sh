#!/bin/bash

set -euo pipefail

INTERNAL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$INTERNAL_DIR/.." && pwd)"
# shellcheck source=../lib/config.sh
source "$SCRIPTS_DIR/lib/config.sh"
INTERFACE="$WADVPN_WAN_INTERFACE"
WG_INTERFACE="$WADVPN_WG_INTERFACE"
VPN_NETWORK="$WADVPN_VPN_NETWORK"
CLIENTS_JSON="$PROJECT_DIR/config/clients.json"

iptables -D FORWARD -i "$WG_INTERFACE" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -o "$WG_INTERFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$WG_INTERFACE" -o "$WG_INTERFACE" -s "$VPN_NETWORK" -j DROP 2>/dev/null || true
iptables -t nat -D POSTROUTING -s "$VPN_NETWORK" -o "$INTERFACE" -j MASQUERADE 2>/dev/null || true

RULE_INDEX=1
while IFS= read -r client; do
    ADDRESS=$(echo "$client" | jq -r '.address')
    [ -n "$ADDRESS" ] || continue
    iptables -C FORWARD -i "$WG_INTERFACE" -o "$WG_INTERFACE" -s "$ADDRESS" -j DROP >/dev/null 2>&1 || iptables -I FORWARD "$RULE_INDEX" -i "$WG_INTERFACE" -o "$WG_INTERFACE" -s "$ADDRESS" -j DROP
    RULE_INDEX=$((RULE_INDEX + 1))
done < <(jq -c '.clients[]? | select(.enabled == true and (.isolated // false) == true)' "$CLIENTS_JSON")

iptables -C FORWARD -i "$WG_INTERFACE" -j ACCEPT >/dev/null 2>&1 || iptables -I FORWARD "$RULE_INDEX" -i "$WG_INTERFACE" -j ACCEPT
RULE_INDEX=$((RULE_INDEX + 1))
iptables -C FORWARD -o "$WG_INTERFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1 || iptables -I FORWARD "$RULE_INDEX" -o "$WG_INTERFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -C POSTROUTING -s "$VPN_NETWORK" -o "$INTERFACE" -j MASQUERADE >/dev/null 2>&1 || iptables -t nat -A POSTROUTING -s "$VPN_NETWORK" -o "$INTERFACE" -j MASQUERADE
