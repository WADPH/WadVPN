#!/bin/bash

set -euo pipefail

PROJECT_DIR="/opt/wad-vpn"

if [ "$EUID" -ne 0 ]; then
    echo "Run this script as root."
    exit 1
fi

echo "========================================"
echo "         WadVPN Installer"
echo "========================================"
echo

"$PROJECT_DIR/scripts/install-packages.sh"
"$PROJECT_DIR/scripts/configure-system.sh"
"$PROJECT_DIR/scripts/apply-routes.sh"
"$PROJECT_DIR/scripts/apply-firewall.sh"
"$PROJECT_DIR/scripts/apply-wireguard.sh"
"$PROJECT_DIR/scripts/verify.sh"

echo
echo "========================================"
echo " Installation completed successfully."
echo "========================================"
