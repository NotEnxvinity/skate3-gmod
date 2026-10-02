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
| `setup/` | `skate3-gmod-setup.sh`: converts your `default.xex` data on Linux |

The Skate 3 host is a git dependency on
[chasmlol/2010-rust-rewrite-mashup](https://github.com/chasmlol/2010-rust-rewrite-mashup)'s
`skate-host` (built from the engine at `cb79689`); none of its code is copied in.

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
