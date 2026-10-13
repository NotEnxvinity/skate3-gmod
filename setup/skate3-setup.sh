#!/usr/bin/env bash
# S3GM (Skate 3 in Garry's Mod) setup for Linux / SteamOS and macOS (where
# S3GM-setup-Mac.command starts it with a double-click).
#
#   ./skate3-setup.sh                                        uses an .iso beside
#                                                            the setup, or asks
#   ./skate3-setup.sh --game "/path/to/Skate 3.iso"          (or default.xex)
#                     [--gmod <garrysmod folder>] [--with-addon]
#
# The Lua addon comes from the Steam Workshop; this installs the skate module
# and converts what the mod needs from your disc. Nothing needs installing
# first: without a Python 3.10 to 3.13, the first run downloads a portable
# Python (python-build-standalone, the build uv uses) into
# ~/.cache/skate3-gmod, along with the Skate 3 engine's converters, vgmstream,
# and numpy and Pillow in a private venv there, so SteamOS's read-only root
# is never touched.
set -euo pipefail

# The engine revision the skate host in Cargo.toml was built from.
ENGINE_URL=https://github.com/SK8-ENGINE/skate-3-rust-engine
ENGINE_REV=cb7968930f14dad38457e98720d1a274e469eec2
PYTHON_BUILD=20250818
PYTHON_VERSION=3.13.7
VGMSTREAM_URL=https://github.com/vgmstream/vgmstream-releases/releases/download/nightly/vgmstream-linux-cli.tar.gz
mac=false
if [ "$(uname -s)" = Darwin ]; then
    mac=true
    VGMSTREAM_URL=https://github.com/vgmstream/vgmstream-releases/releases/download/nightly/vgmstream-mac-cli.tar.gz
    # Downloaded zips are quarantined; Gatekeeper would refuse the module.
    xattr -dr com.apple.quarantine "$(cd "$(dirname "$0")" && pwd)" 2>/dev/null || true
fi

here=$(cd "$(dirname "$0")" && pwd)
cache=${XDG_CACHE_HOME:-$HOME/.cache}/skate3-gmod
die() {
    echo "error: $*" >&2
    if $mac; then
        osascript -e 'on run argv' -e 'display alert "S3GM setup" message (item 1 of argv) as critical' -e 'end run' "$*" >/dev/null 2>&1 || true
    fi
    exit 1
}
fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

command -v curl >/dev/null || die "curl is required"
mkdir -p "$cache"

# What to convert: --game, an .iso or an extracted game (default.xex, or a
# folder holding it) beside the setup or in the folder holding it, or one
# picked in a window.
game=
rest=()
while [ $# -gt 0 ]; do
    case $1 in
        --game) game=${2:-}; shift 2 || shift ;;
        *) rest+=("$1"); shift ;;
    esac
done
if [ -z "$game" ]; then
    found=()
    for dir in "$here" "$(dirname "$here")"; do
        for f in "$dir"/*.iso "$dir"/*.ISO "$dir"/default.xex "$dir"/*/default.xex; do
            [ -f "$f" ] && found+=("$f")
        done
    done
    if [ ${#found[@]} -eq 1 ]; then
        game=${found[0]}
        echo "Using $game"
    elif $mac; then
        game=$(osascript -e 'POSIX path of (choose file with prompt "Select your Skate 3 (Xbox 360) disc image (.iso), or default.xex")' 2>/dev/null) \
            || die "No Skate 3 disc picked, so nothing was installed."
    fi
fi

# A Python that numpy 2.2 has wheels for: 3.10 to 3.13.
python=
for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" >/dev/null &&
        "$candidate" -c 'import sys; sys.exit(not (3, 10) <= sys.version_info[:2] <= (3, 13))' 2>/dev/null; then
        python=$(command -v "$candidate")
        break
    fi
done
if [ -z "$python" ]; then
    case "$(uname -s)-$(uname -m)" in
        Darwin-arm64) triple=aarch64-apple-darwin ;;
        Darwin-x86_64) triple=x86_64-apple-darwin ;;
        Linux-x86_64) triple=x86_64-unknown-linux-gnu ;;
        *) die "no Python 3.10 to 3.13 found; install one (python.org) and run this again" ;;
    esac
    portable="$cache/python-$PYTHON_VERSION"
    if [ ! -x "$portable/bin/python3" ]; then
        echo "Fetching Python $PYTHON_VERSION for the converters (one time, nothing is installed)..."
        rm -rf "$portable.partial"
        mkdir -p "$portable.partial"
        fetch "https://github.com/astral-sh/python-build-standalone/releases/download/$PYTHON_BUILD/cpython-$PYTHON_VERSION+$PYTHON_BUILD-$triple-install_only.tar.gz" \
            "$cache/python.tar.gz"
        tar -xzf "$cache/python.tar.gz" -C "$portable.partial" --strip-components 1
        rm -f "$cache/python.tar.gz"
        rm -rf "$portable"
        mv "$portable.partial" "$portable"
    fi
    python="$portable/bin/python3"
fi

engine="$cache/engine-${ENGINE_REV:0:7}"
if [ ! -d "$engine/tools/asset_pipeline" ]; then
    echo "Fetching the Skate 3 engine's converters (${ENGINE_REV:0:7}, one time)..."
    rm -rf "$engine.partial"
    mkdir -p "$engine.partial"
    # A zip of that revision, so git (and on a Mac, Xcode's tools) isn't needed.
    fetch "$ENGINE_URL/archive/$ENGINE_REV.zip" "$cache/engine.zip"
    "$python" -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
        "$cache/engine.zip" "$engine.partial"
    rm -f "$cache/engine.zip"
    # GitHub puts everything in one folder named after the repo and revision.
    rm -rf "$engine"
    mv "$engine.partial"/* "$engine"
    rm -rf "$engine.partial"
fi

vgmstream="$cache/vgmstream/vgmstream-cli"
if [ ! -x "$vgmstream" ]; then
    echo "Fetching vgmstream, which decodes the disc's sounds (one time)..."
    mkdir -p "$cache/vgmstream"
    fetch "$VGMSTREAM_URL" "$cache/vgmstream/cli.tar.gz"
    tar -xzf "$cache/vgmstream/cli.tar.gz" -C "$cache/vgmstream" vgmstream-cli
    rm -f "$cache/vgmstream/cli.tar.gz"
    chmod +x "$vgmstream"
    if $mac; then xattr -d com.apple.quarantine "$vgmstream" 2>/dev/null || true; fi
fi

venv="$cache/venv"
if [ ! -x "$venv/bin/python" ] || ! "$venv/bin/python" -c 'import numpy, PIL' 2>/dev/null; then
    echo "Creating a Python environment for the converters (one time)..."
    rm -rf "$venv"
    "$python" -m venv "$venv"
    "$venv/bin/python" -m pip install -q --upgrade pip
    "$venv/bin/python" -m pip install -q "numpy==2.2.6" "Pillow==11.3.0"
fi

export SKATE3_ENGINE="$engine" SKATE3_VGMSTREAM="$vgmstream"
setup=("$venv/bin/python" "$here/skate3_setup.py")
# No disc picked yet (Linux): the setup window asks for it.
if [ -z "$game" ]; then
    exec "${setup[@]}" ${rest[@]+"${rest[@]}"}
fi
status=0
"${setup[@]}" --game "$game" ${rest[@]+"${rest[@]}"} || status=$?
if [ $status -eq 2 ] && $mac; then
    # Garry's Mod wasn't found in any Steam library.
    gmod=$(osascript -e 'POSIX path of (choose folder with prompt "Garry'\''s Mod was not found. Select its garrysmod folder (Steam > Garry'\''s Mod > Manage > Browse local files, then garrysmod).")' 2>/dev/null) \
        || die "No garrysmod folder picked, so nothing was installed."
    status=0
    "${setup[@]}" --game "$game" --gmod "$gmod" ${rest[@]+"${rest[@]}"} || status=$?
fi
[ $status -eq 0 ] || die "Setup stopped with an error; the Terminal window says why."
if $mac; then
    osascript -e 'display dialog "All set! Subscribe to S3GM on the Steam Workshop if you haven'\''t, then start Garry'\''s Mod, load a map and equip the Skateboard." with title "S3GM setup" buttons {"OK"} default button 1' >/dev/null 2>&1 || true
fi
