#!/usr/bin/env bash
# Converts your own Skate 3 (Xbox 360) data for the Gmod skate mode.
#
#   ./skate3-gmod-setup.sh --xex "/path/to/Skate 3/default.xex" [--out DIR]
#
# Runs outside the game. Needs git and python3; numpy and Pillow are installed
# into a private venv, so SteamOS's read-only root is never touched.
set -euo pipefail

# The engine revision the skate host in Cargo.toml was built from.
ENGINE_URL=https://github.com/SK8-ENGINE/skate-3-rust-engine
ENGINE_REV=cb79689

here=$(cd "$(dirname "$0")" && pwd)
cache=${XDG_CACHE_HOME:-$HOME/.cache}/skate3-gmod
xex=
out=

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case $1 in
        --xex) xex=${2:-}; shift 2 ;;
        --out) out=${2:-}; shift 2 ;;
        -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$xex" ] || die "pass --xex with your extracted Skate 3 default.xex"

if [ -z "$out" ]; then
    # Native Linux Gmod and Proton Gmod share this install folder.
    gmod="$HOME/.local/share/Steam/steamapps/common/GarrysMod/garrysmod"
    [ -d "$gmod" ] || die "Garry's Mod not found at $gmod; pass --out"
    out="$gmod/data/skate3"
fi

command -v git >/dev/null || die "git is required"
command -v python3 >/dev/null || die "python3 is required"
mkdir -p "$cache"

engine="$cache/engine-$ENGINE_REV"
if [ ! -d "$engine/tools" ]; then
    echo "Fetching the Skate 3 engine's converters ($ENGINE_REV)..."
    rm -rf "$engine.partial"
    git init -q "$engine.partial"
    git -C "$engine.partial" remote add origin "$ENGINE_URL"
    git -C "$engine.partial" fetch -q --depth 1 origin "$ENGINE_REV" \
        || git -C "$engine.partial" fetch -q origin
    git -C "$engine.partial" checkout -q "$ENGINE_REV"
    mv "$engine.partial" "$engine"
fi

venv="$cache/venv"
if [ ! -x "$venv/bin/python" ]; then
    echo "Creating a Python environment for the converters..."
    python3 -m venv "$venv"
    "$venv/bin/python" -m pip install -q --upgrade pip
    "$venv/bin/python" -m pip install -q "numpy==2.2.6" "Pillow==11.3.0"
fi

exec "$venv/bin/python" "$here/convert.py" --engine "$engine" --xex "$xex" --out "$out"
