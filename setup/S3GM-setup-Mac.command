#!/bin/bash
# S3GM setup for macOS: double-click this. The first time macOS blocks it as a
# downloaded script: System Settings > Privacy & Security > Open Anyway, or run
# it as  bash S3GM-setup-Mac.command  in Terminal. It runs
# setup-files/skate3-setup.sh, which opens the setup window.
here=$(cd "$(dirname "$0")" && pwd)
files="$here/setup-files"
# A source checkout (setup/) keeps everything beside this script.
[ -f "$files/skate3-setup.sh" ] || files="$here"
# No __pycache__ folders left behind in the download.
export PYTHONDONTWRITEBYTECODE=1
xattr -dr com.apple.quarantine "$here" 2>/dev/null || true
bash "$files/skate3-setup.sh" "$@"
echo
echo "You can close this window now."
