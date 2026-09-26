#!/bin/bash

# Shared helpers for the client registry (config/clients.json).
# Requires PROJECT_DIR, so source lib/config.sh first.

CLIENTS_JSON="$PROJECT_DIR/config/clients.json"

# ipset names are limited to 31 characters and carry the "wadvpn-g-" prefix.
GROUP_NAME_PATTERN='^[A-Za-z0-9_-]{1,22}$'

valid_group_name() {
    [[ "$1" =~ $GROUP_NAME_PATTERN ]]
}

# Run a jq filter over clients.json and replace the file only when the result
# is valid JSON.  Extra arguments are passed to jq before the filter.
update_clients_json() {
    local tmp
    tmp=$(mktemp "$CLIENTS_JSON.XXXXXX")
    if jq "$@" "$CLIENTS_JSON" > "$tmp" && jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
        chmod --reference="$CLIENTS_JSON" "$tmp"
        mv "$tmp" "$CLIENTS_JSON"
    else
        rm -f "$tmp"
        echo "Failed to update $CLIENTS_JSON; the file was left unchanged." >&2
        return 1
    fi
}
