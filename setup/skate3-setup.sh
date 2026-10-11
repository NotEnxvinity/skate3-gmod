#!/usr/bin/env bash
# S3GM (Skate 3 in Garry's Mod) setup, run with your system's Python.
#
#   ./skate3-setup.sh --game "/path/to/Skate 3/default.xex"   (or a .iso)
#   ./skate3-setup.sh                                        the setup window
#
# Installs the skate module, the converted game data, the disc's sounds and
# the park pieces into Garry's Mod, plus this build's Lua addon (it loads
# instead of the Workshop one). The first run fetches the Skate 3 engine's
# converters and vgmstream into ~/.cache/skate3-gmod, and numpy and Pillow
# into a private venv there, so SteamOS's read-only root is never touched.
set -euo pipefail

# The engine revision the skate host in Cargo.toml was built from.
ENGINE_URL=https://github.com/SK8-ENGINE/skate-3-rust-engine
ENGINE_REV=cb7968930f14dad38457e98720d1a274e469eec2
VGMSTREAM_URL=https://github.com/vgmstream/vgmstream-releases/releases/download/nightly/vgmstream-linux-cli.tar.gz

here=$(cd "$(dirname "$0")" && pwd)
cache=${XDG_CACHE_HOME:-$HOME/.cache}/skate3-gmod
die() { echo "error: $*" >&2; exit 1; }

command -v git >/dev/null || die "git is required"
command -v python3 >/dev/null || die "python3 is required"
mkdir -p "$cache"

engine="$cache/engine-${ENGINE_REV:0:7}"
if [ ! -d "$engine/tools/asset_pipeline" ]; then
    echo "Fetching the Skate 3 engine's converters (${ENGINE_REV:0:7}, one time)..."
    rm -rf "$engine.partial"
    git init -q "$engine.partial"
    git -C "$engine.partial" remote add origin "$ENGINE_URL"
    git -C "$engine.partial" fetch -q --depth 1 origin "$ENGINE_REV" \
        || git -C "$engine.partial" fetch -q origin
    git -C "$engine.partial" checkout -q "$ENGINE_REV"
    mv "$engine.partial" "$engine"
fi

vgmstream="$cache/vgmstream/vgmstream-cli"
if [ ! -x "$vgmstream" ]; then
    echo "Fetching vgmstream, which decodes the disc's sounds (one time)..."
    mkdir -p "$cache/vgmstream"
    python3 -c 'import sys, urllib.request; urllib.request.urlretrieve(sys.argv[1], sys.argv[2])' \
        "$VGMSTREAM_URL" "$cache/vgmstream/cli.tar.gz"
    tar -xzf "$cache/vgmstream/cli.tar.gz" -C "$cache/vgmstream" vgmstream-cli
    rm -f "$cache/vgmstream/cli.tar.gz"
    chmod +x "$vgmstream"
fi

venv="$cache/venv"
if [ ! -x "$venv/bin/python" ] || ! "$venv/bin/python" -c 'import numpy, PIL' 2>/dev/null; then
    echo "Creating a Python environment for the converters (one time)..."
    rm -rf "$venv"
    python3 -m venv "$venv"
    "$venv/bin/python" -m pip install -q --upgrade pip
    "$venv/bin/python" -m pip install -q "numpy==2.2.6" "Pillow==11.3.0"
fi

export SKATE3_ENGINE="$engine" SKATE3_VGMSTREAM="$vgmstream"
# --with-addon keeps this build's Lua; without it setup removes addons/skate3.
exec "$venv/bin/python" "$here/skate3_setup.py" --with-addon "$@"
