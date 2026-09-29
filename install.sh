#!/usr/bin/env bash
# Installs the logimouse and logi commands into uv's tool bin directory (usually ~/.local/bin),
# then, when Noctalia is installed, registers this repository as a plugin source and enables
# the Logi Mouse plugin. Adding the widget to the bar is left to Settings → Bar.
# Editable install: edits to the source take effect without reinstalling.
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
plugin_id="cmoro-deusto/logimouse"
source_name="logimouse"

if ! command -v uv >/dev/null 2>&1; then
    echo "uv is not installed: see https://docs.astral.sh/uv/getting-started/installation/" >&2
    exit 1
fi

uv tool install --editable --reinstall "$project_dir"

bin_dir="$(realpath -m "$(uv tool dir --bin)")"
case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "Warning: $bin_dir is not on your PATH; run 'uv tool update-shell' to add it." >&2 ;;
esac
echo "Installed: run 'logimouse' or 'logi'"

if ! command -v noctalia >/dev/null 2>&1; then
    echo "Noctalia not found: skipping the plugin"
    exit 0
fi

if noctalia msg plugins source list | grep -q "^$source_name "; then
    echo "Plugin source '$source_name' already registered"
else
    noctalia msg plugins source add "$source_name" path "$project_dir"
fi
noctalia msg plugins enable "$plugin_id"
echo "Plugin $plugin_id enabled: add 'Logi Mouse' to the bar from Settings → Bar"
