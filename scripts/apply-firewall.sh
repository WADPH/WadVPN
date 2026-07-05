#!/bin/bash

set -euo pipefail

INTERFACE=$(jq -r '.server.interface // "ens3"' /opt/wad-vpn/config/settings.json)
CLIENTS_JSON="/opt/wad-vpn/config/clients.json"

iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i wg0 -o wg0 -s 10.200.0.0/24 -j DROP 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 10.200.0.0/24 -o "$INTERFACE" -j MASQUERADE 2>/dev/null || true

RULE_INDEX=1
while IFS= read -r client; do
    ADDRESS=$(echo "$client" | jq -r '.address')
    [ -n "$ADDRESS" ] || continue
    iptables -C FORWARD -i wg0 -o wg0 -s "$ADDRESS" -j DROP >/dev/null 2>&1 || iptables -I FORWARD "$RULE_INDEX" -i wg0 -o wg0 -s "$ADDRESS" -j DROP
    RULE_INDEX=$((RULE_INDEX + 1))
done < <(jq -c '.clients[]? | select(.enabled == true and (.isolated // false) == true)' "$CLIENTS_JSON")

iptables -C FORWARD -i wg0 -j ACCEPT >/dev/null 2>&1 || iptables -I FORWARD "$RULE_INDEX" -i wg0 -j ACCEPT
RULE_INDEX=$((RULE_INDEX + 1))
iptables -C FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1 || iptables -I FORWARD "$RULE_INDEX" -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -C POSTROUTING -s 10.200.0.0/24 -o "$INTERFACE" -j MASQUERADE >/dev/null 2>&1 || iptables -t nat -A POSTROUTING -s 10.200.0.0/24 -o "$INTERFACE" -j MASQUERADE
