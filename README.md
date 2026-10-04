# skate3-gmod

A toggleable Skate 3 skating mode for Garry's Mod, driven by the
[Skate 3 Rust engine](https://github.com/SK8-ENGINE/skate-3-rust-engine)
through a native binary module, the way [G64](https://github.com/ckosmic/g64)
drives libsm64. Targets 64-bit Gmod on SteamOS: native Linux and Proton.

**No Skate 3 files ship here.** You convert your own extracted Xbox 360
`default.xex` with the setup script.

Work in progress. See [docs/architecture.md](docs/architecture.md) for the plan.

## Layout

| path | what |
|---|---|
| `native/skate-bridge` | Source collision to Skate collision, auto grind-rail detection, re-exports the skate host |
| `native/skate-headless` | CLI that runs a skater on a test park without Gmod (milestone 1) |
| `native/gmod-skate` | `gmcl_skate3`, the binary module: Lua bindings, BSP collision, worker thread, gamepad |
| `addon/` | The Lua addon: `skate3_toggle`, camera, server position sync |
| `setup/` | `skate3-gmod-setup.sh`: converts your `default.xex` data on Linux |

The Skate 3 host is a git dependency on
[chasmlol/2010-rust-rewrite-mashup](https://github.com/chasmlol/2010-rust-rewrite-mashup)'s
`skate-host` (built from the engine at `cb79689`); none of its code is copied in.

## Install (Steam Deck / SteamOS)

1. Download **skate3-gmod-linux-x64** from the latest CI run and unzip it.
2. Convert your Skate 3 data straight into the game folder (needs git + python3):
   ```sh
   skate3-gmod/setup/skate3-gmod-setup.sh --xex "/path/to/Skate 3/default.xex"
   ```
   It defaults to `~/.local/share/Steam/steamapps/common/GarrysMod/garrysmod/data/skate3`.
3. Copy the zip's `garrysmod` folder over `GarrysMod/garrysmod`. That adds
   `lua/bin/gmcl_skate3_{linux64,win64}.dll` and `addons/skate3`.
4. Use 64-bit Garry's Mod: Steam → Garry's Mod → Properties → Betas →
   **x86-64**. Native Linux loads the `linux64` module, Proton the `win64` one.
5. Plug in a controller, load a map, and equip the **Skateboard** (spawn menu →
   Weapons → Skate 3). You start on foot with the board in hand; **Y** gets
   on and off it, as in Skate 3. Switch weapons to leave skate mode.
   `skate3_toggle` in the console starts and ends it without the weapon (bind
   it: `bind j skate3_toggle`).

Steam Input: Garry's Mod's controller layout must be a gamepad layout (Steam →
Garry's Mod → Controller settings → a "Gamepad" template), not keyboard and
mouse, or the pad shows up but sends no buttons. `skate3_debug_input 1` shows
what the mod receives; pressing A should show `buttons 1000`.

Console variables: `skate3_camera low`, `normal` or `high` sets the camera
height (`skate3_camera_cycle` steps through them, handy on a bind),
`skate3_volume` sets the skate sounds' volume from 0 to 1, `skate3_score_hud 0`
hides the trick score, `skate3_debug_rails 1` draws the grind rails found in the
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

- Skate 3 engine and converters: SK8-ENGINE/skate-3-rust-engine (dumbad, Chasm and contributors).
- Headless host, collision handoff and rail finder: chasmlol/2010-rust-rewrite-mashup (Apache-2.0). See [NOTICE](NOTICE).
- Module architecture: ckosmic/g64.

Unofficial fan project, not affiliated with EA or Facepunch.
