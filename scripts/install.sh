#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

if [ "$EUID" -ne 0 ]; then
    echo "Run this script as root."
    exit 1
fi

echo "========================================"
echo "         WadVPN Installer"
echo "========================================"
echo

"$SCRIPT_DIR/install/install-packages.sh"
"$SCRIPT_DIR/install/configure-system.sh"
"$SCRIPT_DIR/internal/apply-wireguard.sh"
"$SCRIPT_DIR/verify.sh"

echo
echo "========================================"
echo " Installation completed successfully."
echo "========================================"
