#!/bin/bash

set -euo pipefail

PROJECT_DIR="/opt/wad-vpn"

echo "========================================"
echo "         WadVPN Installer"
echo "========================================"
echo

if [ "$EUID" -ne 0 ]; then
    echo "Run this script as root."
    exit 1
fi

"$PROJECT_DIR/scripts/install-packages.sh"
"$PROJECT_DIR/scripts/configure-system.sh"
"$PROJECT_DIR/scripts/apply-routes.sh"
"$PROJECT_DIR/scripts/apply-firewall.sh"
"$PROJECT_DIR/scripts/verify.sh"

echo
echo "========================================"
echo " Installation completed successfully."
echo "========================================"
