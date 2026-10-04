#!/usr/bin/env bash
# Builds against a patched copy of the Skate 3 host: clones the mashup at the
# rev Cargo.toml pins, applies native/patches/*.patch, and points Cargo at it.
# CI runs this before building; the clone lives outside the repository.
set -euo pipefail
cd "$(dirname "$0")/.."
url=https://github.com/chasmlol/2010-rust-rewrite-mashup
rev=$(sed -n 's/^skate-host = .*rev = "\([0-9a-f]*\)".*/\1/p' Cargo.toml)
dir=${SKATE_HOST_DIR:-$PWD/../mashup}
rm -rf "$dir"
git clone -q --filter=blob:none "$url" "$dir"
git -C "$dir" checkout -q "$rev"
for p in native/patches/*.patch; do git -C "$dir" apply "$PWD/$p"; done
mkdir -p .cargo
cat >> .cargo/config.toml <<TOML
[patch."$url"]
skate-host = { path = "$dir/skate/crates/skate-host" }
TOML
echo "skate-host patched at $dir"
