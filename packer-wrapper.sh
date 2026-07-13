#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
plugin_root="$repo_root/vendor/packer/plugins"
plugin_binary="$plugin_root/github.com/hashicorp/amazon/packer-plugin-amazon_v1.8.1_x5.0_linux_amd64"

if [[ "$(uname -s)" != "Linux" || "$(uname -m)" != "x86_64" ]]; then
    echo "The vendored Packer plugin supports Linux x86_64 only." >&2
    exit 1
fi

if [[ ! -f "$plugin_binary" ]]; then
    echo "The vendored Amazon plugin is missing." >&2
    exit 1
fi

# Archive extraction and some file-copy methods can discard Git's executable
# mode. Repair that common case before asking Packer to load the plugin.
if [[ ! -x "$plugin_binary" ]]; then
    echo "Setting the vendored Amazon plugin permissions to 0755."
    if ! chmod 0755 "$plugin_binary"; then
        echo "Unable to make the vendored Amazon plugin executable." >&2
        exit 1
    fi
fi

# chmod cannot overcome a filesystem mounted with noexec.
if [[ ! -x "$plugin_binary" ]]; then
    echo "The vendored Amazon plugin is on a filesystem that does not allow execution." >&2
    exit 1
fi

if ! command -v packer >/dev/null 2>&1; then
    echo "Packer is not installed or is not on PATH." >&2
    exit 1
fi

# Packer uses this namespaced, repo-local directory and therefore never needs
# to discover or download the required Amazon plugin from the public internet.
export PACKER_PLUGIN_PATH="$plugin_root"
# Disable HashiCorp update checks and telemetry, which otherwise contact the
# public checkpoint service even when all plugins are installed locally.
export CHECKPOINT_DISABLE=1
exec packer "$@"
