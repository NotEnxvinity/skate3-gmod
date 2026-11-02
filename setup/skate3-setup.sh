#!/usr/bin/env bash
# S3GM (Skate 3 in Garry's Mod) setup for Linux / SteamOS and macOS.
# S3GM-setup-Linux.sh and S3GM-setup-Mac.command start it with a double-click.
#
#   ./skate3-setup.sh                                        the setup window,
#                                                            filled in with an
#                                                            .iso beside it
#   ./skate3-setup.sh --game "/path/to/Skate 3.iso"          no window
#                     [--gmod <garrysmod folder>] [--no-addon]
#
# This installs the S3GM addon and skate module into Garry's Mod and converts
# what the mod needs from your disc. Nothing needs installing
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
    elif [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        if command -v kdialog >/dev/null; then kdialog --title "S3GM setup" --error "$*" >/dev/null 2>&1 || true
        elif command -v zenity >/dev/null; then zenity --error --title "S3GM setup" --text "$*" >/dev/null 2>&1 || true
        fi
    fi
    exit 1
}
fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

command -v curl >/dev/null || die "curl is required"
if $mac && [ ! -f "$here/bin/gmcl_skate3_osx64.dll" ]; then
    die "This is the Windows and Linux download. Get the Mac one, S3GM-v2.3.0-Mac.zip, from the same Discord post."
fi
mkdir -p "$cache"

# What to convert: --game (then no window), or the window, filled in with an
# .iso or an extracted game (default.xex, or a folder holding it) beside the
# setup or in the folder holding it.
game=
given=false
rest=()
while [ $# -gt 0 ]; do
    case $1 in
        --game) game=${2:-}; given=true; shift 2 || shift ;;
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
    fi
fi

# A Python that numpy 2.2 has wheels for: 3.10 to 3.13, able to make a venv.
# On a Mac it needs tkinter for the setup window; on Linux the window is a page
# in the browser (its own fonts and theme), so no Tk is needed.
if $mac; then need_tk=tkinter; else need_tk=; fi
python=
for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" >/dev/null &&
        "$candidate" -c "import sys, venv, ensurepip${need_tk:+, $need_tk}; sys.exit(not (3, 10) <= sys.version_info[:2] <= (3, 13))" 2>/dev/null; then
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
    [ -d "$engine/tools/asset_pipeline" ] ||
        die "The Skate 3 engine's converters were fetched, but $engine/tools/asset_pipeline is missing. Delete $cache and run this again."
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
if [ ! -x "$venv/bin/python" ] || ! "$venv/bin/python" -c "import numpy, PIL${need_tk:+, $need_tk}" 2>/dev/null; then
    echo "Creating a Python environment for the converters (one time)..."
    rm -rf "$venv"
    "$python" -m venv "$venv"
    "$venv/bin/python" -m pip install -q --upgrade pip
    "$venv/bin/python" -m pip install -q "numpy==2.2.6" "Pillow==11.3.0"
fi

export SKATE3_ENGINE="$engine" SKATE3_VGMSTREAM="$vgmstream"
setup=("$venv/bin/python" "$here/skate3_setup.py")
if ! $given; then
    # The window: the player checks the Garry's Mod folder and disc, then presses Install.
    echo "Opening the S3GM setup window..."
    if [ -n "$game" ]; then
        exec "${setup[@]}" --window --game "$game" ${rest[@]+"${rest[@]}"}
    fi
    exec "${setup[@]}" --window ${rest[@]+"${rest[@]}"}
fi
"${setup[@]}" --game "$game" ${rest[@]+"${rest[@]}"} || die "Setup stopped with an error; the lines above say why."
