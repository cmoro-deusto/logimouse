#!/usr/bin/env bash
# Removes what install.sh set up: the Noctalia plugin and its source (when Noctalia is
# installed), then the logimouse and logi commands.
set -euo pipefail

plugin_id="cmoro-deusto/logimouse"
source_name="logimouse"

if command -v noctalia >/dev/null 2>&1; then
    if noctalia msg plugins list | grep -q "^$plugin_id "; then
        noctalia msg plugins disable "$plugin_id" || true
    fi
    if noctalia msg plugins source list | grep -q "^$source_name "; then
        noctalia msg plugins source remove "$source_name"
        echo "Removed plugin source '$source_name'"
    fi
fi

if ! command -v uv >/dev/null 2>&1; then
    echo "uv is not installed, so logimouse can't be installed through it either" >&2
    exit 1
fi

if uv tool list 2>/dev/null | grep -q '^logimouse '; then
    uv tool uninstall logimouse
    echo "Uninstalled logimouse and logi"
else
    echo "logimouse is not installed"
fi
