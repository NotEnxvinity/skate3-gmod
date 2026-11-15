#!/usr/bin/env bash
# S3GM setup for Linux / SteamOS: double-click this in the file manager (on
# SteamOS, in Desktop Mode) and choose Execute/Run. It opens a terminal that
# shows the one-time downloads, then the setup window. It runs
# setup-files/skate3-setup.sh (everything but the launchers lives in setup-files).
here=$(cd "$(dirname "$0")" && pwd)
files="$here/setup-files"
# A source checkout (setup/) keeps everything beside this script.
[ -f "$files/skate3-setup.sh" ] || files="$here"
# No __pycache__ folders left behind in the download.
export PYTHONDONTWRITEBYTECODE=1
if [ ! -t 1 ] && [ -z "${S3GM_IN_TERMINAL:-}" ]; then
    # Started from the file manager: show the progress in a terminal window.
    export S3GM_IN_TERMINAL=1
    me="$here/$(basename "$0")"
    for term in konsole gnome-terminal kgx xfce4-terminal mate-terminal lxterminal alacritty kitty xterm x-terminal-emulator; do
        command -v "$term" >/dev/null || continue
        if [ "$term" = gnome-terminal ]; then exec "$term" -- bash "$me" "$@"; fi
        exec "$term" -e bash "$me" "$@"
    done
fi
status=0
bash "$files/skate3-setup.sh" "$@" || status=$?
# Finish in the setup window (or closing it) closes this terminal too; it
# only stays open, with the log, when something went wrong.
if [ -n "${S3GM_IN_TERMINAL:-}" ] && [ "$status" -ne 0 ]; then
    echo
    read -r -p "Press Enter to close this window." _ || true
fi
exit $status
