#!/usr/bin/env bash
# Like s3gm-ride-check.sh, but replays the rides with the Windows build of the
# engine under Proton, the way Garry's Mod runs it there, so the maths match
# the game's (the Linux build can drift away from a ride and miss the glitch).
# Zips what it finds into ~/Downloads/s3gm-ride-report.zip.
set -u
cd "$(dirname "$0")"
S=${STEAM_DIR:-$HOME/.local/share/Steam}
LIBS=$( (echo "$S"; sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"/\1/p' "$S/steamapps/libraryfolders.vdf" 2>/dev/null) | awk '!seen[$0]++')
LIB=
while IFS= read -r lib; do
	if [ -d "$lib/steamapps/common/GarrysMod/garrysmod" ]; then LIB=$lib; break; fi
done <<< "$LIBS"
[ -n "$LIB" ] || { echo "Couldn't find Garry's Mod in your Steam libraries." >&2; exit 1; }
DATA=$LIB/steamapps/common/GarrysMod/garrysmod/data/skate3
[ -d "$DATA/assets" ] || { echo "No Skate 3 data at $DATA/assets (run the S3GM setup first)." >&2; exit 1; }
ls "$DATA"/rides/*.sk3r >/dev/null 2>&1 || { echo "No saved rides in $DATA/rides." >&2; exit 1; }

# The Proton Garry's Mod uses, else the newest one installed.
PROTON=
info=$LIB/steamapps/compatdata/4000/config_info
if [ -f "$info" ]; then
	dir=$(grep -o '^.*/files/' "$info" | head -n 1)
	[ -n "$dir" ] && [ -x "${dir%files/}proton" ] && PROTON=${dir%files/}proton
fi
if [ -z "$PROTON" ]; then
	while IFS= read -r lib; do
		for p in "$lib"/steamapps/common/Proton*/proton; do [ -x "$p" ] && PROTON=$p; done
	done <<< "$LIBS"
fi
[ -n "$PROTON" ] || { echo "Couldn't find Proton in your Steam libraries." >&2; exit 1; }
echo "Using $PROTON"

export STEAM_COMPAT_CLIENT_INSTALL_PATH=$S
export STEAM_COMPAT_DATA_PATH=$HOME/.cache/s3gm-ride-check-prefix
export WINEDEBUG=-all
mkdir -p "$STEAM_COMPAT_DATA_PATH"
# Proton's own launcher drops a console program's output, so Proton sets up
# its prefix once and its Wine then runs the replays directly.
[ -d "$STEAM_COMPAT_DATA_PATH/pfx" ] || "$PROTON" run cmd /c exit > /dev/null 2>&1
export WINEPREFIX=$STEAM_COMPAT_DATA_PATH/pfx
WINE=$(dirname "$PROTON")/files/bin/wine
[ -x "$WINE" ] || WINE=$(dirname "$PROTON")/dist/bin/wine
# Runs the replay with stdout to $1 and stderr to $2, both Linux paths.
if [ -x "$WINE" ] && "$WINE" cmd /c echo s3gm-ok 2>/dev/null | grep -q s3gm-ok; then
	replay() { "$WINE" ./skate-headless.exe --assets "Z:$DATA/assets" --replay "Z:$ride" > "$1" 2> "$2"; }
else
	# No usable Wine of its own: cmd writes the files inside Proton.
	echo "(running through Proton's launcher)"
	replay() { "$PROTON" run cmd /c "\"Z:$PWD/skate-headless.exe\" --assets \"Z:$DATA/assets\" --replay \"Z:$ride\" > \"Z:$1\" 2> \"Z:$2\"" > /dev/null 2>&1; }
fi

OUT=$HOME/Downloads/s3gm-ride-report
rm -rf "$OUT" && mkdir -p "$OUT"
echo "$PROTON / $WINE" > "$OUT/proton.txt"
for ride in "$DATA"/rides/*.sk3r; do
	name=$(basename "$ride" .sk3r)
	echo "Replaying $name under Proton (the first one also sets Proton up, give it a few minutes)..."
	replay "$OUT/$name.txt" "$OUT/$name-err.txt"
	tail -n 1 "$OUT/$name.txt"
	tick=$(sed -n 's/^BROKE at .*tick \([0-9]*\)).*/\1/p' "$OUT/$name.txt" | tr -d '\r')
	if [ -n "$tick" ]; then
		echo "  broke again, tracing the ticks before it..."
		start=$(( tick > 12 ? tick - 12 : 0 ))
		SKATE3_AUDIT_OFFBOARD_TICKS=$start:$(( tick + 12 )) \
			replay "$OUT/$name-traced.txt" "$OUT/$name-trace.txt"
	fi
done
cd "$HOME/Downloads" && rm -f s3gm-ride-report.zip && zip -qr s3gm-ride-report.zip s3gm-ride-report
echo
echo "All done. Send ~/Downloads/s3gm-ride-report.zip to Claude."
