#!/usr/bin/env bash
# S3GM setup for Linux / SteamOS: double-click this in the file manager (on
# SteamOS, in Desktop Mode) and choose Execute/Run. It opens a terminal that
# shows the one-time downloads, then the setup window. It runs skate3-setup.sh.
here=$(cd "$(dirname "$0")" && pwd)
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
bash "$here/skate3-setup.sh" "$@" || status=$?
if [ -n "${S3GM_IN_TERMINAL:-}" ]; then
    echo
    read -r -p "Press Enter to close this window." _ || true
fi
exit $status
