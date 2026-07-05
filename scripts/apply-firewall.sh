#!/bin/bash
set -e

# Remove old rules if they exist
iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 10.200.0.0/24 -o ens3 -j MASQUERADE 2>/dev/null || true

# Insert rules before UFW reject rules
iptables -I FORWARD 1 -i wg0 -j ACCEPT
iptables -I FORWARD 2 -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

iptables -t nat -A POSTROUTING -s 10.200.0.0/24 -o ens3 -j MASQUERADE
