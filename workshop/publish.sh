#!/usr/bin/env bash
# Packs addon/ and uploads it as an update to the Workshop item, with Garry's
# Mod's own gmad and gmpublish. Run it from anywhere in a copy of this repo,
# with Steam running and Garry's Mod closed:
#
#     workshop/publish.sh "What changed"
#
# Garry's Mod run through Proton only has the Windows tools, so they run
# through Proton the way Steam runs the game.
set -euo pipefail

ITEM=3814357793
changes=${1:?usage: workshop/publish.sh \"what changed\"}
cd "$(dirname "$0")/.."
S=${STEAM_DIR:-$HOME/.local/share/Steam}
# Garry's Mod can live in any Steam library (an SD card, a second drive).
LIB=
while IFS= read -r lib; do
	if [ -d "$lib/steamapps/common/GarrysMod/bin" ]; then LIB=$lib; break; fi
done < <(echo "$S"; sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"/\1/p' "$S/steamapps/libraryfolders.vdf" 2>/dev/null)
[ -n "$LIB" ] || { echo "Couldn't find Garry's Mod in your Steam libraries." >&2; exit 1; }
BIN=$LIB/steamapps/common/GarrysMod/bin
COMPAT=$LIB/steamapps/compatdata/4000
[ -d "$COMPAT" ] || COMPAT=$S/steamapps/compatdata/4000

tool() {
	if [ -x "$BIN/linux64/$1" ]; then
		"$BIN/linux64/$1" "${@:2}"
		return
	fi
	local proton
	proton="$( (ls -d "$S"/steamapps/common/Proton*Experimental "$LIB"/steamapps/common/Proton*Experimental; ls -d "$S"/steamapps/common/Proton* "$LIB"/steamapps/common/Proton*) 2>/dev/null | head -1 || true)/proton"
	[ -x "$proton" ] || { echo "Neither Garry's Mod's Linux $1 nor Proton was found." >&2; exit 1; }
	STEAM_COMPAT_CLIENT_INSTALL_PATH="$S" STEAM_COMPAT_DATA_PATH="$COMPAT" \
		SteamAppId=4000 SteamGameId=4000 "$proton" run "$BIN/win64/$1.exe" "${@:2}"
}

rm -f skate3.gma
tool gmad create -folder addon -out skate3.gma
[ -f skate3.gma ] || { echo "gmad didn't make skate3.gma" >&2; exit 1; }
tool gmpublish update -addon skate3.gma -id "$ITEM" -icon workshop/icon.jpg -changes "$changes"
rm -f skate3.gma
