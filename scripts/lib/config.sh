#!/bin/bash

# Shared WadVPN configuration.  Every executable script that needs deployment
# settings sources this file instead of reading configuration JSON directly.

CONFIG_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$CONFIG_LIB_DIR/../.." && pwd)"
ENV_FILE="${WADVPN_ENV_FILE:-$PROJECT_DIR/.env}"

if [ ! -r "$ENV_FILE" ]; then
    echo "WadVPN environment file not found or unreadable: $ENV_FILE" >&2
    echo "Copy .env.example to .env and set its values." >&2
    return 1
fi

# .env is an administrator-controlled shell-style KEY=value file.
# shellcheck disable=SC1090
source "$ENV_FILE"

require_env() {
    local name="$1"
    if [ -z "${!name:-}" ]; then
        echo "Required setting is empty: $name" >&2
        return 1
    fi
}

require_env WADVPN_PROJECT_NAME
require_env WADVPN_PROJECT_VERSION
require_env WADVPN_WAN_INTERFACE
require_env WADVPN_WG_INTERFACE
require_env WADVPN_WG_ADDRESS
require_env WADVPN_VPN_NETWORK
require_env WADVPN_WG_LISTEN_PORT
require_env WADVPN_DNS_SERVERS

WADVPN_ENDPOINT="${WADVPN_PUBLIC_HOSTNAME:-${WADVPN_PUBLIC_IP:-}}"
require_env WADVPN_ENDPOINT

if ! [[ "$WADVPN_WG_LISTEN_PORT" =~ ^[0-9]+$ ]] ||
   [ "$WADVPN_WG_LISTEN_PORT" -lt 1 ] ||
   [ "$WADVPN_WG_LISTEN_PORT" -gt 65535 ]; then
    echo "WADVPN_WG_LISTEN_PORT must be between 1 and 65535." >&2
    return 1
fi
