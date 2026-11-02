# S3GM v2.4.0 test 5 (BETA, not a release)

An early build of v2.4.0, pushed so the work is safe on GitHub. Main and the v2.3.1 release are untouched; use v2.3.1 unless you want to test.

## New since v2.3.1
- In-game phone-style menu (hold L1): Skate 3 look, Settings, Games, Go To / Place Marker
- Hall of Meat can use Skate 3's own skeleton (from your disc), with the X-ray lines as an option
- Customize: D-pad right in the menu opens Playermodel and Board lists (works with Enhanced PlayerModel Selector)
- Update checker (one GitHub "latest release" request after joining)
- Text with g/j/p/y tails no longer clipped; HD UI pictures switch (`skate3_ui_hd 0`)
- Setup: optional browser window (`--web`); normal window is unchanged

## Known issues
- **Hall of Meat can still linger after a respawn or marker teleport.** Not fixed in this build.
- Windows setup and real SteamOS are lightly tested; the customizer and skeleton lighting have had one tester.

## Install
Run the S3GM setup from this build (it extracts to its own `S3GM-setup` folder); setup must be rerun to get the new fonts and the skeleton. It reads everything from your own Skate 3 disc. Never replace your whole garrysmod folder.
