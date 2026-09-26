#!/bin/bash

# IPv4 validation helpers shared by the management scripts.

valid_ipv4() {
    local address="$1" octet
    [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local octets
    IFS='.' read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
        [ "$((10#$octet))" -le 255 ] || return 1
    done
}

valid_ipv4_cidr() {
    local cidr="$1"
    [[ "$cidr" == */* ]] || return 1
    local prefix="${cidr#*/}"
    valid_ipv4 "${cidr%/*}" && [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && [ "$prefix" -le 32 ]
}

ipv4_to_int() {
    local address="$1" a b c d
    IFS='.' read -r a b c d <<< "$address"
    echo $((10#$a * 16777216 + 10#$b * 65536 + 10#$c * 256 + 10#$d))
}

cidr_contains() {
    local cidr="$1" address="$2" prefix mask network_int address_int
    valid_ipv4_cidr "$cidr" && valid_ipv4 "$address" || return 1
    prefix="${cidr#*/}"
    network_int=$(ipv4_to_int "${cidr%/*}")
    address_int=$(ipv4_to_int "$address")
    if [ "$prefix" -eq 0 ]; then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi
    (( (network_int & mask) == (address_int & mask) ))
}
