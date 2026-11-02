# skate3-gmod

**S3GM**: Skate 3's real skating in Garry's Mod. Its own physics, flick-it
tricks, grinds, manuals and bails, on any map, with any playermodel. It's driven
by the [Skate 3 Rust engine](https://github.com/SK8-ENGINE/skate-3-rust-engine)
through a native binary module, the way [G64](https://github.com/ckosmic/g64)
drives libsm64. Runs on 64-bit Garry's Mod on Windows, Linux and SteamOS
(native or Proton), and on Macs.

**No Skate 3 files ship here.** The setup app converts your own Xbox 360 disc
(an ISO or the extracted folder) on your machine.

How it's put together: [docs/architecture.md](docs/architecture.md) (the
original plan; the code has grown past it).

## Layout

| path | what |
|---|---|
| `native/gmod-skate` | `gmcl_skate3`, the binary module: Lua bindings, BSP collision, worker thread, gamepad, the retail sound engine's output |
| `native/skate-bridge` | Source collision to Skate collision, auto grind-rail detection, re-exports the skate host |
| `native/skate-aems` | Skate 3's AEMS audio runtime, vendored from SK8V |
| `native/skate-xma` | Bit-exact EA-XMA decoder for the disc's sounds, vendored from SK8V |
| `native/skate-xex` | Reads the player's `default.xex` so setup can pull the audio tuning out of it, vendored from SK8V |
| `native/skate-tools` | The decoder and XEX reader as a small library for setup on Apple-silicon Macs |
| `native/skate-headless` | CLI that runs a skater on a test park without Gmod |
| `native/patches/` | Patches applied to the skate host by `native/patch-engine.sh` (CI runs it on a fresh clone) |
| `addon/` | The Lua addon: the Skateboard weapon, camera, HUD, sounds, parks, multiplayer sync |
| `setup/` | The setup app (`skate3_setup.py`, reads ISOs with `xdvdfs.py`), its per-OS launchers, and `skate3-gmod-setup.sh`, the Linux script it grew from |
| `workshop/` | Workshop description, icon, and `publish.sh` for updates |
| `tools/` | `s3gm-ride-check`: replays saved glitched rides through the engine with tracing on |

The Skate 3 host is a git dependency on
[chasmlol/2010-rust-rewrite-mashup](https://github.com/chasmlol/2010-rust-rewrite-mashup)'s
`skate-host` (built from the engine at `cb79689`); none of its code is copied in.

## Install

Prefer to watch it? There's a video walkthrough of the install: https://youtu.be/oGdIwMNwp14

1. Get the **S3GM setup zip** for your computer. Releases are posted in the
   **gmod-releases** channel of Enxvinity's Atelier on Discord (Macs need the
   Mac zip). Extract it anywhere; you get one folder, `S3GM-setup`.
2. Run the setup for your system from that folder:
   - Windows: `S3GM-setup-Windows.bat` (or drag your `.iso` onto it)
   - Linux / SteamOS: `S3GM-setup-Linux.sh` (Desktop Mode; pick Execute/Run,
     or run `bash S3GM-setup-Linux.sh`)
   - Mac: `S3GM-setup-Mac.command` (the first time, System Settings → Privacy
     & Security → Open Anyway, or run `bash S3GM-setup-Mac.command`)
3. The window shows your `garrysmod` folder and your Skate 3 (Xbox 360) disc
   image (`.iso`, or `default.xex` in an extracted copy). Fix either with
   Browse and press Install. Setup installs the Lua addon and the skate module
   into `garrysmod/lua/bin`, converts what the mod needs from your disc into
   `garrysmod/data/skate3`, and decodes the disc's sounds (with
   [vgmstream](https://github.com/vgmstream/vgmstream)) into
   `garrysmod/sound/skate3`. Leave "Skate 3's own sound engine" ticked (beta,
   a few GB and a few more minutes): it also prepares the game's own audio for
   the retail sound engine. Run the new release's setup after each update.
   Without a window, give the launcher the paths:
   `S3GM-setup-Linux.sh --game <iso or default.xex> [--gmod <garrysmod folder>]`
   (the Windows and Mac launchers take the same options).
4. Use 64-bit Garry's Mod: Steam → Garry's Mod → Properties → Betas →
   **x86-64**. Native Linux loads the `linux64` module, Proton and Windows the
   `win64` one, a Mac the `osx64` one.
5. Plug in a controller (keyboard and mouse works too, but it's early), load a
   map, and equip the **Skateboard** (spawn menu → Weapons → Skate 3). You
   start on the board; **Y** gets off and on it, as in Skate 3. Switch weapons
   to leave skate mode. Hold **L1** for the quick menu: **D-pad down** drops a
   session marker; hold **D-pad up** to go back to it (the hold gets longer the
   further away you are, like Skate 3).
   `skate3_toggle` in the console starts and ends it without the weapon (bind
   it: `bind j skate3_toggle`).

The [Workshop item](https://steamcommunity.com/sharedfiles/filedetails/?id=3814357793)
carries the same Lua addon. You don't need it, since setup installs the addon
itself, but keeping it subscribed is fine as long as it's the same version. If
the game ever seems older than what setup said it installed, unsubscribe from
the Workshop copy. `--no-addon` skips setup's copy (and removes an old one) so
the Workshop one loads.

Joining someone's server? You need the setup too: every skater's simulation
runs from their own disc.

Publishing a Workshop update (the item's owner, Steam running, Garry's Mod
closed): `workshop/publish.sh "what changed"` packs `addon/` with gmad and
uploads it with gmpublish, through Proton when Garry's Mod runs under it.

Steam Input: Garry's Mod's controller layout must be a gamepad layout (Steam →
Garry's Mod → Controller settings → a "Gamepad" template), not keyboard and
mouse, or the pad shows up but sends no buttons. `skate3_debug_input 1` shows
what the mod receives; pressing A should show `buttons 1000`.

Parks and ramps: setup also converts the park editor's pieces and Skate 3's
skateparks from your disc. Open the **Skate 3** tab in the spawn menu, pick a
piece (left click) and place it with the tool gun, or right click to drop it at
your crosshair. Move pieces with the physics gun; reload with it to lock a piece
in place. Each skatepark also has a map of its own (`gm_skate3_maloof`, `gm_skate3_megapark` and so on, in
the map list): an open grass field that builds the park in the middle of it when it loads
(admins can also right click a park in the tab to load its map, or "Build here" on any map). If Garry's Mod ever crashes
while a park loads, the next start builds parks without Garry's Mod physics
until you run `skate3_park_safe 0`; the board rides them either way.

Settings live in the spawn menu under Utilities > Skate 3: stance (regular or
goofy), camera height, sounds and volume, and the score widget. The same as
console variables: `skate3_stance regular` or `goofy`, `skate3_camera low`,
`normal` or `high` (`skate3_camera_cycle` steps through them, handy on a bind),
`skate3_sounds hl2`, `disc` (Skate 3's own sounds, which setup installs) or `off`, `skate3_bail_sounds disc` or `hl2` (bails with the disc sounds), `skate3_bone_sounds auto`, `disc`, `hl2` or `off` (the cracks of a fracture or a break), `skate3_multiplier_sounds 0` (the chime when the score multiplier goes up), `skate3_volume` from 0 to 1, `skate3_score_hud 0`
hides the trick score, and `skate3_score_style minimal`, `world` (floating beside the skater) or `hl2` picks its look. For debugging, `skate3_debug_rails 1` draws the grind rails found in the
map, `skate3_debug_input 1` shows the controller input, `skate3_debug_sounds 1` prints each bail hit, bone break and multiplier chime, `skate3_sound_scan menu` plays a bank's sounds one by one (and `skate3_menu_names mult` lists the interface sounds by name), `skate3_data_path` points at converted data somewhere else, and the
server's `skate3_enabled 0` turns the mode off.

The Skate 3 board is drawn from your converted data and your playermodel is
posed from the skater's skeleton. Other players see you skate: your game sends
your pose and they draw a posed copy of your playermodel with the board
(`skate3_others_body real` poses their real body instead, and
`skate3_debug_others 1` shows what arrives from each skater). Multiplayer fix
by undead_corporation.

Other players are solid. Every skater's simulation runs on their own computer,
so each game checks its skater against the others and bails it when it runs
into someone hard enough (a head-on meeting at pushing speed does it; side by
side, or a slow catch-up, doesn't). A walking player can't be bailed: the
skater who hits them bails, and the server shoves them. On foot, B (F on a
keyboard) or R1 (Ctrl) attacks: with the board in your hand you smack with it
(longer reach, can catch a few people), without it you punch, one hand then
the other. Anyone hit on a board comes off it, anyone walking is shoved. The server decides:
`skate3_player_collision 0` turns crashes off, `skate3_player_collision_speed`
is the closing speed in metres a second that crashes (4), `skate3_player_hits 0`
turns punches and swings off (as does a server that keeps players from hurting
each other, such as Sandbox's `sbox_playershurtplayers 0`), and
`skate3_hit_damage` is the health a punch takes (a swing takes twice; 0, the
default, hurts nobody). `skate3_melee 0` takes your own punches and smacks
off, and `skate3_debug_players 1` shows who is close and how fast you'd crash.

## Try the headless runner

```sh
# 1. Convert your own Skate 3 data (needs git + python3; makes a private venv)
setup/skate3-gmod-setup.sh --xex "/path/to/Skate 3/default.xex" --out ./skate3-data

# 2. Run a skater on the test park
cargo run --release -p skate-headless -- --assets ./skate3-data/assets --ticks 600
```

Without `--assets` it only builds the test park and prints the rails it found.

## Credits

- Skate 3 engine and converters: [SK8-ENGINE/skate-3-rust-engine](https://github.com/SK8-ENGINE/skate-3-rust-engine)
  (dumbad, Chasm and contributors), used with their permission
  ([issue #34](https://github.com/SK8-ENGINE/skate-3-rust-engine/issues/34)) on the condition that
  this mod stays free. It always will be.
- Headless host, collision handoff and rail finder: [chasmlol/2010-rust-rewrite-mashup](https://github.com/chasmlol/2010-rust-rewrite-mashup)
  (Apache-2.0, text in [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt)). See [NOTICE](NOTICE).
- Module architecture: inspired by [ckosmic/g64](https://github.com/ckosmic/g64). No code taken.
- Skate 3's sound engine: [becaring/SK8V](https://github.com/becaring/SK8V) (Apache-2.0; its EA-XMA
  decoder is LGPL-2.1-or-later), ported for this mod.
- Park pieces and the Mega Park stadium readers: [NativeX World Studio](https://github.com/NativeXex/nativex-world-studio-skate3)
  and [SK8-Engine](https://github.com/SK8-ENGINE/SK8-Engine) (MIT, see `setup/skate3_formats/`).
- Multiplayer board fix: undead_corporation. Map testing: gumballegal.
- Sound bank research: [doriangironde/skate-3-rust-macos](https://github.com/doriangironde/skate-3-rust-macos)
  and Hailey-Ross's audio work on SK8-ENGINE. Sounds are decoded on your machine by
  [vgmstream](https://github.com/vgmstream/vgmstream).

## License

GPL-3.0, see [LICENSE](LICENSE). Code ported from chasmlol's project stays under
Apache-2.0 as NOTICE describes. Skate 3 and its assets belong to Electronic Arts;
none of them are in this repository or its downloads.

Unofficial fan project, not affiliated with EA or Facepunch.
