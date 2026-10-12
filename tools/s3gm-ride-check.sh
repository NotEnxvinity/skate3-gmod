#!/usr/bin/env bash
# Replays the rides S3GM saved when it glitched (garrysmod/data/skate3/rides)
# through the Skate 3 engine on this machine, with the engine's tracing on for
# the ticks just before each break, and zips what it finds into
# ~/Downloads/s3gm-ride-report.zip. Uses the Skate 3 data the setup made;
# nothing from the disc goes into the report.
set -u
cd "$(dirname "$0")"
S=${STEAM_DIR:-$HOME/.local/share/Steam}
# Garry's Mod can live in any Steam library (an SD card, a second drive).
LIB=
while IFS= read -r lib; do
	if [ -d "$lib/steamapps/common/GarrysMod/garrysmod" ]; then LIB=$lib; break; fi
done < <(echo "$S"; sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"/\1/p' "$S/steamapps/libraryfolders.vdf" 2>/dev/null)
[ -n "$LIB" ] || { echo "Couldn't find Garry's Mod in your Steam libraries." >&2; exit 1; }
DATA=$LIB/steamapps/common/GarrysMod/garrysmod/data/skate3
[ -d "$DATA/assets" ] || { echo "No Skate 3 data at $DATA/assets (run the S3GM setup first)." >&2; exit 1; }
ls "$DATA"/rides/*.sk3r >/dev/null 2>&1 || { echo "No saved rides in $DATA/rides." >&2; exit 1; }

OUT=$HOME/Downloads/s3gm-ride-report
rm -rf "$OUT" && mkdir -p "$OUT"
chmod +x ./skate-headless
for ride in "$DATA"/rides/*.sk3r; do
	name=$(basename "$ride" .sk3r)
	echo "Replaying $name (this can take a few minutes)..."
	./skate-headless --assets "$DATA/assets" --replay "$ride" > "$OUT/$name.txt" 2>&1
	tail -n 1 "$OUT/$name.txt"
	tick=$(sed -n 's/^BROKE at .*tick \([0-9]*\)).*/\1/p' "$OUT/$name.txt")
	if [ -n "$tick" ]; then
		echo "  broke again, tracing the ticks before it..."
		start=$(( tick > 25 ? tick - 25 : 0 ))
		SKATE3_AUDIT_OFFBOARD_TICKS=$start:$(( tick + 5 )) \
			./skate-headless --assets "$DATA/assets" --replay "$ride" > /dev/null 2> "$OUT/$name-trace.txt"
	fi
done
cd "$HOME/Downloads" && rm -f s3gm-ride-report.zip && zip -qr s3gm-ride-report.zip s3gm-ride-report
echo
echo "All done. Send ~/Downloads/s3gm-ride-report.zip to Claude."
