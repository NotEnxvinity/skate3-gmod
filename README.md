# skate3-gmod

A toggleable Skate 3 skating mode for Garry's Mod, driven by the
[Skate 3 Rust engine](https://github.com/SK8-ENGINE/skate-3-rust-engine)
through a native binary module, the way [G64](https://github.com/ckosmic/g64)
drives libsm64. Targets 64-bit Gmod on SteamOS: native Linux and Proton.

**No Skate 3 files ship here.** The setup app converts your own Xbox 360 disc
(an ISO or the extracted folder) on your machine.

Work in progress. See [docs/architecture.md](docs/architecture.md) for the plan.

## Layout

| path | what |
|---|---|
| `native/skate-bridge` | Source collision to Skate collision, auto grind-rail detection, re-exports the skate host |
| `native/skate-headless` | CLI that runs a skater on a test park without Gmod (milestone 1) |
| `native/gmod-skate` | `gmcl_skate3`, the binary module: Lua bindings, BSP collision, worker thread, gamepad |
| `addon/` | The Lua addon: `skate3_toggle`, camera, server position sync |
| `setup/` | The setup app (`skate3_setup.py`, reads ISOs with `xdvdfs.py`) and `skate3-gmod-setup.sh`, the Linux script it grew from |

The Skate 3 host is a git dependency on
[chasmlol/2010-rust-rewrite-mashup](https://github.com/chasmlol/2010-rust-rewrite-mashup)'s
`skate-host` (built from the engine at `cb79689`); none of its code is copied in.

## Install (Windows, Linux or SteamOS)

1. Subscribe to [**Skate 3 in Gmod**](https://steamcommunity.com/sharedfiles/filedetails/?id=3814357793)
   on the Steam Workshop. That's the Lua
   addon; the Workshop can't carry the native skate engine, so that comes from
   the setup app (the way [G64](https://github.com/ckosmic/g64) does it).
2. Download **skate3-gmod-setup-Windows.zip** or **skate3-gmod-setup-Linux.zip**
   from the [latest release](https://github.com/NotEnxvinity/skate3-gmod/releases/latest)
   and unzip it.
3. Run `skate3-gmod-setup` and pick your Skate 3 (Xbox 360) disc image
   (`.iso`), or `default.xex` in an extracted copy. It finds Garry's Mod,
   installs the skate module into `garrysmod/lua/bin`, converts what the mod
   needs from your disc into `garrysmod/data/skate3`, and decodes the disc's
   skate sounds (with [vgmstream](https://github.com/vgmstream/vgmstream))
   into `garrysmod/sound/skate3`. Run the new release's setup after each
   update. Without a window:
   `skate3-gmod-setup --game <iso or default.xex> [--gmod <garrysmod folder>]`.
4. Use 64-bit Garry's Mod: Steam → Garry's Mod → Properties → Betas →
   **x86-64**. Native Linux loads the `linux64` module, Proton the `win64` one.
5. Plug in a controller, load a map, and equip the **Skateboard** (spawn menu →
   Weapons → Skate 3). You start on foot with the board in hand; **Y** gets
   on and off it, as in Skate 3. Switch weapons to leave skate mode.
   **D-pad down** drops a session marker; hold **D-pad up** to go back to it
   (the hold gets longer the further away you are, like Skate 3).
   `skate3_toggle` in the console starts and ends it without the weapon (bind
   it: `bind j skate3_toggle`).

Testing a build whose Lua isn't on the Workshop yet: tick "Also install the Lua
addon" in setup (or pass `--with-addon`). That copy in `garrysmod/addons/skate3`
loads instead of the Workshop one until setup runs again without it, which
removes it.

Publishing a Workshop update (the item's owner, Steam running, Garry's Mod
closed): `workshop/publish.sh "what changed"` packs `addon/` with gmad and
uploads it with gmpublish, through Proton when Garry's Mod runs under it.

Steam Input: Garry's Mod's controller layout must be a gamepad layout (Steam →
Garry's Mod → Controller settings → a "Gamepad" template), not keyboard and
mouse, or the pad shows up but sends no buttons. `skate3_debug_input 1` shows
what the mod receives; pressing A should show `buttons 1000`.

Settings live in the spawn menu under Utilities > Skate 3: stance (regular or
goofy), camera height, sounds and volume, and the score widget. The same as
console variables: `skate3_stance regular` or `goofy`, `skate3_camera low`,
`normal` or `high` (`skate3_camera_cycle` steps through them, handy on a bind),
`skate3_sounds hl2`, `disc` (Skate 3's own sounds, which setup installs) or `off`, `skate3_bail_sounds disc` or `hl2` (bails with the disc sounds), `skate3_volume` from 0 to 1, `skate3_score_hud 0`
hides the trick score, and `skate3_score_style minimal`, `world` (floating beside the skater) or `hl2` picks its look. For debugging, `skate3_debug_rails 1` draws the grind rails found in the
map, `skate3_debug_input 1` shows the controller input, `skate3_data_path` points at converted data somewhere else, and the
server's `skate3_enabled 0` turns the mode off.

The Skate 3 board is drawn from your converted data and your playermodel is
posed from the skater's skeleton. Other players don't see either yet.

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
- Sound bank research: [doriangironde/skate-3-rust-macos](https://github.com/doriangironde/skate-3-rust-macos)
  and Hailey-Ross's audio work on SK8-ENGINE. Sounds are decoded on your machine by
  [vgmstream](https://github.com/vgmstream/vgmstream).

## License

GPL-3.0, see [LICENSE](LICENSE). Code ported from chasmlol's project stays under
Apache-2.0 as NOTICE describes. Skate 3 and its assets belong to Electronic Arts;
none of them are in this repository or its downloads.

Unofficial fan project, not affiliated with EA or Facepunch.
