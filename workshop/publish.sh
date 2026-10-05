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
BIN=$S/steamapps/common/GarrysMod/bin

tool() {
	if [ -x "$BIN/linux64/$1" ]; then
		"$BIN/linux64/$1" "${@:2}"
		return
	fi
	local proton
	proton="$( (ls -d "$S"/steamapps/common/Proton*Experimental; ls -d "$S"/steamapps/common/Proton*) 2>/dev/null | head -1)/proton"
	[ -x "$proton" ] || { echo "Neither Garry's Mod's Linux $1 nor Proton was found." >&2; exit 1; }
	STEAM_COMPAT_CLIENT_INSTALL_PATH="$S" STEAM_COMPAT_DATA_PATH="$S/steamapps/compatdata/4000" \
		SteamAppId=4000 SteamGameId=4000 "$proton" run "$BIN/win64/$1.exe" "${@:2}"
}

rm -f skate3.gma
tool gmad create -folder addon -out skate3.gma
[ -f skate3.gma ] || { echo "gmad didn't make skate3.gma" >&2; exit 1; }
tool gmpublish update -addon skate3.gma -id "$ITEM" -icon workshop/icon.jpg -changes "$changes"
rm -f skate3.gma
