# Skate 3 mode for Garry's Mod: architecture plan

Status: plan only, no code yet. Read 2026-10-02 from:

- `ckosmic/g64` @ HEAD (Lua addon) and `ckosmic/libsm64-gmod` (its C++ binary module, linked from G64's README)
- `SK8-ENGINE/skate-3-rust-engine` @ `7ae67f2`
- `chasmlol/2010-rust-rewrite-mashup` @ `f608f85`

## TL;DR

The mashup already did the hard part. It turned the Skate 3 engine into a
headless library (`skate/crates/skate-host`, a pinned fork of the engine at
`cb79689`) with a tiny API: `Session::new(triangles, rails, spawn, heading)`,
`activate()`, `advance()`, `pose()`, `install_collision()`. MW2 feeds it
collision triangles plus auto-detected grind rails, then poses its soldier
from the returned skeleton. We do the exact same thing with Gmod instead of
MW2, wrapped in a G64-style binary module.

```
 ┌──────────────── Gmod client (Lua) ────────────────┐
 │ skate_toggle → hide/freeze player, CalcView,      │
 │ pose playermodel, net pose to server              │
 └───────────────▲──────────────────┬────────────────┘
                 │ pose, camera     │ collision tris, toggle, spawn
 ┌───────────────┴──────────────────▼────────────────┐
 │ gmcl_skate3_{linux64,win64}.dll  (Rust cdylib)    │
 │  Lua bindings (`gmod` crate)                      │
 │  worker thread: skate-host Session @ 60 Hz        │
 │  collision: BSP brushes + props → triangles       │
 │  rails::find (from the mashup) → grind rails      │
 │  gamepad: gilrs (Linux) / XInput (Proton)         │
 └───────────────┬───────────────────────────────────┘
                 │ reads
       garrysmod/data/skate3/  ← converted from the user's default.xex
```

## What each repo gives us

### G64: the shape of the addon (copy the pattern, not the code)

- Lua `require("g64")` loads `lua/bin/gmcl_g64_win64.dll`, which registers a
  global `libsm64` table of C functions (`main.cpp:1427`). The module links
  libsm64 and SDL2 (gamepad). The user's ROM path is handed to `GlobalInit`.
- Client-authoritative: Mario simulates on the owner's client, which sends
  pos + anim info to the server every tick (`G64_TRANSMITMOVE`); the server
  rebroadcasts, remote clients replay the animation only.
- World collision: the server streams `Entity(0):GetPhysicsObject():GetMeshConvexes()`
  to the client over net; the client additionally parses displacements and
  static props out of the `.bsp` in Lua (`g64_luabsp.lua`), buckets triangles
  into 1000-unit chunks, caches to `data/g64/cache/`, and loads the chunk under
  Mario each tick. Props are separate "surface objects" moved every tick.
- Player is hidden, movement suppressed via `StartCommand`/`CreateMove`,
  `drive.PlayerStartDriving` with an empty drive mode, camera in `CalcView`.
- Sim tick runs off a `SysTime` timer at 30 Hz in Lua.
- Binaries are not on the Workshop; a separate installer drops them into `lua/bin`.

### skate-3-rust-engine: the physics

- `crates/skate-core` is zero-dependency, `#![forbid(unsafe_code)]`, "no
  rendering, file I/O or ECS". This is the gold.
- `crates/skate-game` is the Bevy app that schedules it (Windows-only build
  scripts, MSVC). We don't want this; we want what the mashup carved out of it.
- Asset setup is Python (`tools/asset_pipeline/asset_exports.py`): reads
  `default.xex` + `data/big/*.big`, writes `skater.glb`, animation banks,
  state graphs, physics skeletons, input config. RefPack decode has a
  pure-Python fallback when `refpack.dll` is missing, so it should run on
  Linux with `python3 + numpy + Pillow` (inferred, not yet run).
- Sim runs at 60 Hz (`skate-host/src/physics/clock.rs`).
- **No LICENSE file in the repo.** See Risks.

### 2010-rust-rewrite-mashup: the handoff we steal

- `skate/crates/skate-host`: the engine's game layer minus rendering. Uses
  Bevy only with `default-features = false` (math + logging, one ECS file).
  Public API in `src/physics/bridge.rs`. Only 23 commits behind engine HEAD.
- `crates/render_anim/src/skate/collision.rs`: turns MW2 collision (clip
  mesh, brushes as plane sets, static models) into triangles, fixes winding,
  dedupes, converts units. MW2 is Z-up inches, **same as Source**, so
  `to_skate(p) = (x, z, -y) * 0.0254` applies unchanged, and `brush_faces()`
  works on Source BSP brushes directly (they're also plane sets).
- `crates/render_anim/src/skate/rails.rs`: engine-agnostic auto rail finder.
  Walkable faces (normal.z > 0.65) → edges where the ground drops ≥3 units and
  nothing rises → merged across seams → chained into polylines. Tuned in
  inches, so Source maps should need little or no retuning. Only touches
  `bevy::math::Vec3`; ports by swapping to `glam`.
- `crates/render_anim/src/skate.rs`: the runtime pattern. One retained session
  per map on a 32 MB-stack worker thread; `Job::{Activate, Step, Suspend}` in,
  `Reply::{Ready, Activated, Pose, Error}` out; fixed-step accumulator capped
  at 0.15 s; epoch counter to drop stale replies. Leaving skate mode only
  suspends; banks and collision stay loaded so re-entry is instant. Its
  Minecraft path rebuilds collision around the skater on a second thread and
  hot-swaps it via `install_collision`, which is exactly what we need for
  Gmod props.
- `rig.rs`: retargets Skate 3 bones onto the MW2 skeleton by name. Same idea
  for ValveBiped.
- `skate/converter/iw4l_skate_convert.py`: thin wrapper over the engine's
  `asset_exports.core` + `.character`, validating `default.xex` + required
  `.big` files and staging output atomically.

## The plan

### 1. Native module: `gmcl_skate3` (Rust cdylib)

Workspace:

```
skate3-gmod/
  native/
    skate-core/      vendored from mashup skate/crates (pinned)
    skate-data/      vendored
    skate-host/      vendored + small patches (below)
    gmod-skate/      the cdylib: Lua bindings, worker, collision, rails, input
  addon/             the Lua addon (Workshop-able, no binaries)
  setup/             converter wrapper + install script for SteamOS
```

Build targets:

- `x86_64-unknown-linux-gnu` → `gmcl_skate3_linux64.dll` (native Linux Gmod on the x86-64 branch)
- `x86_64-pc-windows-gnu` (mingw cross-compile from Linux) → `gmcl_skate3_win64.dll` (Gmod under Proton)

Both need 64-bit Gmod (same as G64). Lua picks the name from `jit.os`.
Lua bindings via the `gmod` crate (gmod-rs), the standard Rust route for Gmod
modules; the alternative is C++ glue on `gmod-module-base` like G64, which
buys nothing here.

Patches to `skate-host`:

1. `InputFrame::from_packets([DevicePacket; 4])` so the host can feed pads it
   polled itself. On non-Windows `platform.rs` currently just reports
   disconnected pads.
2. Optionally drop Bevy for plain `glam` + `log`. Not required, but it cuts
   build time and deps a lot. Do it after it works.

Lua surface (the `skate3` global, mirroring `libsm64`):

| function | what |
|---|---|
| `Init(dataPath)` | validate converted assets, preload animation banks on a thread |
| `LoadWorld(bspBytes, propTris)` | build collision + rails off-thread; returns immediately |
| `WorldStatus()` | `"building" / "ready" / error`, plus triangle and rail counts |
| `Activate(pos, yaw, aspect)` | drop onto the board at the player |
| `Step(dt)` | push dt + polled pad, sim advances in fixed 60 Hz steps on the worker |
| `GetPose()` | root matrix, retargeted ValveBiped bone matrices, camera pos/ang/fov, velocity, state string |
| `Suspend()` | get off; session stays resident |
| `UpdateProps(list)` | hand moving prop hulls for the next collision rebuild |
| `GetRails()` | rail polylines for a debug overlay |
| `GetBoardMesh()` | board vertices/UVs from the converted `skater.glb` |

### 2. Collision handoff (from the mashup, adapted to Source)

Do it natively instead of G64's Lua chunk streaming:

1. Client Lua reads `maps/<map>.bsp` via `file.Read(..., "GAME")` and passes the
   bytes in. Rust parses `LUMP_BRUSHES/BRUSHSIDES/PLANES` (keep
   `CONTENTS_SOLID | CONTENTS_PLAYERCLIP`) and turns each brush into faces with
   the mashup's `brush_faces()`. Displacements come from `LUMP_DISPINFO/DISP_VERTS`.
2. Static props: Lua uses G64's trick (`ents.CreateClientProp` +
   `GetMeshConvexes`, transformed by the static prop lump's origin/angles) and
   passes flat float arrays. The `.phy` files live in VPKs, so Lua is the
   easy path here.
3. Rust: winding fix, dedupe, `rails::find`, `to_skate`, then
   `CollisionBuilder::build`. Cache triangles + rails to
   `data/skate3/cache/<map>.bin` keyed by the bsp's CRC.
4. Dynamic props and func_ brushes: copy the mashup's Minecraft streaming loop.
   Every ~0.25 s, or when the skater moves far, rebuild collision for props
   within a radius on the second thread and `install_collision` the result.
   v1 treats props as static once installed; moving ramps come later.

Grind rails come free from step 3 on any map, the same way the mashup gets
them on MW2 and Minecraft blocks. A `skate3_debug_rails 1` convar draws them.

### 3. Lua addon

- `lua/autorun/skate3_init.lua`: `require("skate3")` behind file and arch
  checks with friendly chat errors (G64's `InitializeWorld` flow). Kick off
  `LoadWorld` at `InitPostEntity`, with a HUD line while it builds.
- Toggle: `concommand skate3_toggle`, bindable (default suggestion J, like
  the mashup), plus a both-sticks-click chord read natively.
- Entering: `Activate(ply:GetPos(), eyeYaw)`, then the G64 player takeover
  (movement zeroed in `StartCommand`, empty drive mode, gmod's own gamepad
  binds swallowed).
- Each frame: `Step(FrameTime())` → `GetPose()` → `CalcView` from the skate
  camera, playermodel posed in `BuildBonePositions`, board drawn as an IMesh
  at the deck transform.
- Leaving or bailing: `Suspend()`, put the player at the skater root, restore
  movetype.
- Rendering: retarget onto the player's own ValveBiped playermodel (the
  mashup's `rig.rs` approach). Every playermodel works, nothing from Skate 3
  is drawn except the board, and remote players see something sane.

### 4. Multiplayer

Client-authoritative, like G64. The owner sends position + ~20 ValveBiped bone
rotations (half-precision quats) + deck transform at 20 Hz, unreliable. The
server validates speed sanity, keeps `ply:SetPos` in sync for PVS and hit
detection, and rebroadcasts. Remote clients interpolate. Remote clients
without Skate 3 data still see the posed playermodel and a placeholder board
(a procedural box IMesh), so nobody needs the game just to watch. A server
convar can disable the mode.

### 5. Input on SteamOS

- Native Linux: `gilrs` (pure Rust, evdev). Steam Input presents the Deck or
  any pad as an Xbox pad, so mapping is trivial.
- Proton: the win64 module uses skate-host's existing XInput path, which Proton
  implements.
- Skate 3 is flick-it, so a controller is required for v1 (same as both
  source projects). Keyboard/mouse is a stretch goal.

### 6. User-supplied `default.xex` setup

Gmod Lua can't spawn processes, and a win64 module under Proton calling Linux
Python is cursed. So setup runs outside the game:

`setup/skate3-gmod-setup.sh --xex /path/to/default.xex`

- Checks for `python3`, `numpy`, `Pillow` and offers a venv if they're missing
  (SteamOS's root fs is read-only, so venv is the default).
- Runs the engine's `asset_exports.core` + `.character` (the mashup
  converter's logic, pinned to the same engine revision as `skate-host`).
- Writes to `<GarrysMod>/garrysmod/data/skate3/assets/`, so the same relative
  path works for native and Proton. Uses an atomic `.partial` swap like the
  mashup.
- Optional: build `librefpack.so` from the engine's `refpack_native.rs` and
  teach `fast_refpack.py` to look for `.so`. That only makes setup faster.
- Rejects ISOs and points to extract-xiso, as the mashup docs do.

Nothing from Skate 3 is shipped. The addon and module contain zero game data.

### 7. Milestones

1. **Headless proof**: vendor skate-host, apply the input patch, build on
   Linux, run setup on a real `default.xex`, tick a session on a flat plane
   from a CLI. This proves Linux builds and the converter before Gmod is
   involved.
2. **Module hello**: `gmcl_skate3_linux64.dll` loads, `Init` works, ticks a
   flat-plane session, and Lua prints the pose.
3. **Skate on gm_construct**: BSP brush collision, toggle, camera, debug
   capsule render.
4. **Rails**: `rails::find` on Source maps, debug overlay, tune constants on
   gm_construct and a skatepark map.
5. **Looks right**: ValveBiped retarget and board mesh.
6. **Props + displacements + cache.**
7. **Multiplayer pose sync.**
8. **Proton build** (mingw) and the SteamOS setup script polish.

## Risks and open questions

- **License (blocker for publishing).** `skate-3-rust-engine` has no LICENSE
  file, so by default it's all rights reserved. The mashup is Apache-2.0
  overall but vendors the engine's crates; its NOTICE doesn't grant a license
  for them. Personal use is fine. A public Workshop or GitHub release needs
  the SK8-ENGINE folks' OK or a license from them.
- **Gmod 64-bit on Linux.** Native Linux needs the x86-64 beta branch.
  32-bit Gmod can't load a 64-bit module (same as G64).
- **Converter on Linux is untested.** `install.py` has Windows-only bits
  (`windll`), but those sit in the install flow, not `asset_exports`
  (inferred from reading; verify in milestone 1).
- **Engine drift.** The mashup pinned `cb79689`, 23 commits behind engine
  HEAD. Start from the mashup's fork and rebase forward later.
- **Scale and feel.** Source's player is ~72 units tall vs. Skate's skater in
  meters. The 0.0254 conversion is physically right, but Gmod maps are
  built for a fast, floaty player, so speed may feel off. A
  `skate3_world_scale` convar applied in `to_skate` is the escape hatch.
- **Workshop can't ship binaries.** Distribute the module via GitHub releases
  plus the setup script, as G64 does with its installer.
