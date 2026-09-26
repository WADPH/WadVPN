#!/bin/bash

set -euo pipefail

INTERNAL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$INTERNAL_DIR/.." && pwd)"
# shellcheck source=../lib/config.sh
source "$SCRIPTS_DIR/lib/config.sh"
# shellcheck source=../lib/clients.sh
source "$SCRIPTS_DIR/lib/clients.sh"
INTERFACE="$WADVPN_WAN_INTERFACE"
WG_INTERFACE="$WADVPN_WG_INTERFACE"
VPN_NETWORK="$WADVPN_VPN_NETWORK"

# Client-to-client traffic is denied unless both ends share a group.  Every
# group is an ipset holding its members' addresses and routed networks.
C2C_CHAIN="WADVPN-C2C"
SET_PREFIX="wadvpn-g-"
TMP_SET_PREFIX="wadvpn-t-"

if ! command -v ipset >/dev/null 2>&1; then
    echo "ipset is not installed. Run scripts/install.sh or: apt install ipset" >&2
    exit 1
fi

GROUPS_LIST=()
while IFS= read -r group; do
    if valid_group_name "$group"; then
        GROUPS_LIST+=("$group")
    else
        echo "Skipping group with invalid name: $group" >&2
    fi
done < <(jq -r '.groups[]?' "$CLIENTS_JSON")

while IFS=$'\t' read -r name group; do
    echo "Client '$name' references unknown group '$group'; ignoring it." >&2
done < <(jq -r '(.groups // []) as $known | .clients[]? | .name as $name | .groups[]? | select(. as $g | $known | index($g) | not) | [$name, .] | @tsv' "$CLIENTS_JSON")

# Fill each group set through a temporary set and swap it in atomically.
for group in "${GROUPS_LIST[@]}"; do
    set_name="$SET_PREFIX$group"
    tmp_set="$TMP_SET_PREFIX$group"
    ipset create -exist "$set_name" hash:net
    ipset create -exist "$tmp_set" hash:net
    ipset flush "$tmp_set"
    while IFS= read -r network; do
        [ -n "$network" ] || continue
        ipset add -exist "$tmp_set" "$network"
    done < <(jq -r --arg group "$group" '.clients[]? | select(.enabled == true and ((.groups // []) | index($group))) | (.address + "/32"), (.routes[]?)' "$CLIENTS_JSON")
    ipset swap "$tmp_set" "$set_name"
    ipset destroy "$tmp_set"
done

# Rebuild the chain in one transaction so traffic never sees a partial state.
{
    echo "*filter"
    echo ":$C2C_CHAIN - [0:0]"
    echo "-A $C2C_CHAIN -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
    for group in "${GROUPS_LIST[@]}"; do
        echo "-A $C2C_CHAIN -m set --match-set $SET_PREFIX$group src -m set --match-set $SET_PREFIX$group dst -j ACCEPT"
    done
    echo "-A $C2C_CHAIN -j DROP"
    echo "COMMIT"
} | iptables-restore --noflush

# Insert the base rules at the top of FORWARD before removing older copies, so
# client-to-client traffic is never left unfiltered.  The group check goes first.
iptables -I FORWARD 1 -i "$WG_INTERFACE" -o "$WG_INTERFACE" -j "$C2C_CHAIN"
iptables -I FORWARD 2 -i "$WG_INTERFACE" -j ACCEPT
iptables -I FORWARD 3 -o "$WG_INTERFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

mapfile -t FORWARD_RULES < <(iptables -S FORWARD | grep '^-A ')
BASE_RULES=("${FORWARD_RULES[@]:0:3}")
for ((number = ${#FORWARD_RULES[@]}; number > 3; number--)); do
    rule="${FORWARD_RULES[number - 1]}"
    for base in "${BASE_RULES[@]}"; do
        [ "$rule" = "$base" ] && iptables -D FORWARD "$number" && break
    done
done

# Remove the per-client DROP rules used before groups existed.
while IFS= read -r rule; do
    read -r -a parts <<< "${rule/#-A /-D }"
    iptables "${parts[@]}"
done < <(iptables -S FORWARD | grep -E -- "^-A FORWARD -s [^ ]+ -i $WG_INTERFACE -o $WG_INTERFACE -j DROP$" || true)

iptables -t nat -C POSTROUTING -s "$VPN_NETWORK" -o "$INTERFACE" -j MASQUERADE >/dev/null 2>&1 || iptables -t nat -A POSTROUTING -s "$VPN_NETWORK" -o "$INTERFACE" -j MASQUERADE

# Drop sets of groups that were deleted or renamed; the chain no longer uses them.
while IFS= read -r set_name; do
    group="${set_name#"$SET_PREFIX"}"
    keep=false
    for known in "${GROUPS_LIST[@]}"; do
        [ "$known" = "$group" ] && keep=true && break
    done
    [ "$keep" = true ] || ipset destroy "$set_name"
done < <(ipset list -n | grep -E "^$SET_PREFIX" || true)
