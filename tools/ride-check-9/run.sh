#!/usr/bin/env bash
# One-paste ride check for when the desktop can't show text: downloads the
# replay tool, replays the saved rides under Proton, and puts the result on
# the clipboard (and in ~/Downloads/s3gm-paste.txt) to paste to Claude.
set -u
cd "$HOME/Downloads" || exit 1
url=${1:?usage: run.sh <zip url>}
{
	echo "== s3gm ride check 9 =="
	curl -fsSL -o S3GM-ride-check-9.zip "$url" || echo "DOWNLOAD FAILED"
	rm -rf S3GM-ride-check
	python3 -m zipfile -e S3GM-ride-check-9.zip . || echo "UNZIP FAILED"
	bash S3GM-ride-check/s3gm-ride-check-proton.sh > s3gm-ride-check-log.txt 2>&1
	echo "== results =="
	grep -h "BROKE\|replayed\|^ride:" s3gm-ride-report/ride-*[0-9].txt 2>/dev/null || echo "NO RESULTS"
	echo "== log tail =="
	tail -n 8 s3gm-ride-check-log.txt
} > s3gm-paste.txt 2>&1
copied=no
if command -v wl-copy >/dev/null && wl-copy < s3gm-paste.txt; then copied=wl-copy
elif command -v qdbus6 >/dev/null && qdbus6 org.kde.klipper /klipper setClipboardContents "$(cat s3gm-paste.txt)"; then copied=qdbus6
elif command -v qdbus >/dev/null && qdbus org.kde.klipper /klipper setClipboardContents "$(cat s3gm-paste.txt)"; then copied=qdbus
elif command -v xclip >/dev/null && xclip -selection clipboard < s3gm-paste.txt; then copied=xclip
fi
echo "copied with $copied" >> s3gm-paste.txt
