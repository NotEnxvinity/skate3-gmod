#!/bin/bash
# S3GM setup for macOS: double-click this (the first time, right-click it and
# pick Open, since it's a downloaded script). It runs skate3-setup.sh beside it.
here=$(cd "$(dirname "$0")" && pwd)
xattr -dr com.apple.quarantine "$here" 2>/dev/null || true
bash "$here/skate3-setup.sh" "$@"
echo
echo "You can close this window now."
