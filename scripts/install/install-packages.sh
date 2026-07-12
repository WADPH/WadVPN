#!/bin/bash

set -euo pipefail

echo "[1/4] Checking packages..."

PACKAGES=(
    wireguard
    wireguard-tools
    jq
    qrencode
)

MISSING=()

for package in "${PACKAGES[@]}"; do
    if ! dpkg -s "$package" >/dev/null 2>&1; then
        MISSING+=("$package")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "Installing packages..."
    apt update
    apt install -y "${MISSING[@]}"
else
    echo "Packages OK."
fi
