//! `gmcl_skate3`: the Skate 3 simulation as a Garry's Mod client module,
//! loaded with `require("skate3")` the way G64 loads libsm64.
//!
//! Everything Lua calls returns immediately: map loading and simulation run on
//! a worker thread, and Lua reads back the latest state.

mod bsp;
mod input;
mod lua;
mod runtime;

use std::ffi::c_int;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use glam::Vec3;
use lua::{Lua, State};
use runtime::{Job, Runtime, Status};

static RUNTIME: Mutex<Option<Runtime>> = Mutex::new(None);

/// Where the setup script writes converted data, relative to the game folder.
const DEFAULT_ASSETS: &str = "garrysmod/data/skate3/assets";

/// Wraps a Lua C function so a panic becomes `nil, message` instead of
/// unwinding into the game.
macro_rules! lua_fn {
    ($name:ident, |$lua:ident| $body:block) => {
        unsafe extern "C" fn $name(state: State) -> c_int {
            let Ok(api) = lua::api() else { return 0 };
            let $lua = Lua { api, state };
            match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> c_int { $body })) {
                Ok(n) => n,
                Err(_) => $lua.fail(concat!(stringify!($name), " panicked")),
            }
        }
    };
}

fn with_runtime<T>(f: impl FnOnce(&Runtime) -> T) -> Option<T> {
    RUNTIME.lock().ok()?.as_ref().map(f)
}

/// The setup script's default output, found from the working directory (the
/// game folder) or, failing that, from the game executable's location.
fn default_assets() -> PathBuf {
    let relative = PathBuf::from(DEFAULT_ASSETS);
    if assets_ready(&relative) {
        return relative;
    }
    std::env::current_exe()
        .ok()
        .and_then(|exe| {
            exe.ancestors()
                .map(|dir| dir.join(DEFAULT_ASSETS))
                .find(|candidate| assets_ready(candidate))
        })
        .unwrap_or(relative)
}

/// Converted assets look like this once the setup script has run.
fn assets_ready(path: &Path) -> bool {
    path.join("private/game.json").is_file()
}

lua_fn!(init, |lua| {
    let path = match lua.string(1).filter(|s| !s.is_empty()) {
        Some(given) => PathBuf::from(given),
        None => default_assets(),
    };
    let path = std::fs::canonicalize(&path).unwrap_or(path);
    if !assets_ready(&path) {
        return lua.fail(&format!(
            "no converted Skate 3 data at {} (run setup/skate3-gmod-setup.sh)",
            path.display()
        ));
    }
    let Ok(mut runtime) = RUNTIME.lock() else {
        return lua.fail("runtime lock poisoned");
    };
    if runtime.is_none() {
        match Runtime::start() {
            Ok(r) => *runtime = Some(r),
            Err(e) => return lua.fail(&e),
        }
    }
    ASSETS.lock().map(|mut a| *a = Some(path.clone())).ok();
    lua.push_str(&path.to_string_lossy());
    1
});

static ASSETS: Mutex<Option<PathBuf>> = Mutex::new(None);

lua_fn!(load_map, |lua| {
    let Some(bsp) = lua.bytes(1) else {
        return lua.fail("LoadMap expects the map's .bsp contents as a string");
    };
    // Optional flat {x1,y1,z1, x2,y2,z2, ...} of extra triangles, such as props.
    let extra = lua
        .numbers(2)
        .unwrap_or_default()
        .chunks_exact(9)
        .map(|t| {
            [
                Vec3::new(t[0], t[1], t[2]),
                Vec3::new(t[3], t[4], t[5]),
                Vec3::new(t[6], t[7], t[8]),
            ]
        })
        .collect();
    let Some(assets) = ASSETS.lock().ok().and_then(|a| a.clone()) else {
        return lua.fail("call skate3.Init first");
    };
    let job = Job::Load {
        assets,
        bsp: bsp.to_vec(),
        extra,
    };
    match with_runtime(|r| r.send(job)) {
        Some(()) => {
            lua.push_bool(true);
            1
        }
        None => lua.fail("call skate3.Init first"),
    }
});

lua_fn!(status, |lua| {
    lua.new_table();
    let pad = input::poll().ok().and_then(|p| p.name);
    if let Some(Ok(s)) = with_runtime(|r| {
        r.shared
            .lock()
            .map(|s| (s.status.clone(), s.triangles, s.rails.len(), s.active))
            .map_err(|_| ())
    }) {
        let (state, triangles, rails, active) = s;
        let (name, error) = match state {
            Status::Idle => ("idle", None),
            Status::Loading => ("loading", None),
            Status::Ready => ("ready", None),
            Status::Failed(e) => ("failed", Some(e)),
        };
        lua.push_str(name);
        lua.set_field(-2, c"state");
        if let Some(e) = error {
            lua.push_str(&e);
            lua.set_field(-2, c"error");
        }
        lua.push_number(triangles as f64);
        lua.set_field(-2, c"triangles");
        lua.push_number(rails as f64);
        lua.set_field(-2, c"rails");
        lua.push_bool(active);
        lua.set_field(-2, c"active");
    } else {
        lua.push_str("uninitialized");
        lua.set_field(-2, c"state");
    }
    if let Some(name) = pad {
        lua.push_str(&name);
        lua.set_field(-2, c"pad");
    }
    1
});

lua_fn!(activate, |lua| {
    let (Some(x), Some(y), Some(z), Some(yaw)) =
        (lua.number(1), lua.number(2), lua.number(3), lua.number(4))
    else {
        return lua.fail("Activate expects x, y, z, yaw[, aspect]");
    };
    let aspect = lua.number(5).unwrap_or(16. / 9.) as f32;
    let ready = with_runtime(|r| {
        r.shared
            .lock()
            .map(|s| matches!(s.status, Status::Ready))
            .unwrap_or(false)
    });
    if ready != Some(true) {
        return lua.fail("the map's skate collision isn't ready yet");
    }
    with_runtime(|r| {
        r.send(Job::Activate {
            pos: Vec3::new(x as f32, y as f32, z as f32),
            yaw_degrees: yaw as f32,
            aspect,
        })
    });
    lua.push_bool(true);
    1
});

lua_fn!(step, |lua| {
    let dt = lua.number(1).unwrap_or(0.) as f32;
    let aspect = lua.number(2).unwrap_or(16. / 9.) as f32;
    let controls = match input::poll() {
        Ok(pad) => pad.controls,
        Err(e) => return lua.fail(&format!("gamepad: {e}")),
    };
    with_runtime(|r| {
        r.send(Job::Step {
            dt,
            controls,
            aspect,
        })
    });
    0
});

lua_fn!(suspend, |lua| {
    with_runtime(|r| r.send(Job::Suspend));
    let _ = lua;
    0
});

lua_fn!(get_pose, |lua| {
    let pose = with_runtime(|r| r.shared.lock().ok().and_then(|s| s.pose.clone())).flatten();
    let Some(p) = pose else {
        lua.push_nil();
        return 1;
    };
    lua.new_table();
    for (name, v) in [
        (c"pos", p.pos),
        (c"forward", p.forward),
        (c"up", p.up),
        (c"velocity", p.velocity),
    ] {
        lua.push_vec(v.to_array());
        lua.set_field(-2, name);
    }
    lua.push_number(f64::from(p.speed));
    lua.set_field(-2, c"speed");
    lua.push_str(&p.state);
    lua.set_field(-2, c"state");
    lua.push_number(p.tick as f64);
    lua.set_field(-2, c"tick");
    if let Some(c) = p.camera {
        lua.new_table();
        for (name, v) in [(c"pos", c.pos), (c"forward", c.forward), (c"up", c.up)] {
            lua.push_vec(v.to_array());
            lua.set_field(-2, name);
        }
        lua.push_number(f64::from(c.fov));
        lua.set_field(-2, c"fov");
        lua.set_field(-2, c"camera");
    }
    1
});

lua_fn!(get_rails, |lua| {
    let rails = with_runtime(|r| r.shared.lock().map(|s| s.rails.clone()).unwrap_or_default())
        .unwrap_or_default();
    lua.new_table();
    for (i, rail) in rails.iter().enumerate() {
        lua.new_table();
        for (j, p) in rail.iter().enumerate() {
            lua.push_vec(p.to_array());
            lua.set_index(-2, j as c_int + 1);
        }
        lua.set_index(-2, i as c_int + 1);
    }
    1
});

lua_fn!(version, |lua| {
    lua.push_str(env!("CARGO_PKG_VERSION"));
    1
});

/// # Safety
/// Called by Garry's Mod with a valid Lua state when the module is required.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gmod13_open(state: State) -> c_int {
    let Ok(api) = lua::api() else { return 0 };
    let lua = Lua { api, state };
    lua.new_table();
    for (name, f) in [
        (c"Init", init as lua::CFunction),
        (c"LoadMap", load_map),
        (c"Status", status),
        (c"Activate", activate),
        (c"Step", step),
        (c"Suspend", suspend),
        (c"GetPose", get_pose),
        (c"GetRails", get_rails),
        (c"Version", version),
    ] {
        lua.push_function(f);
        lua.set_field(-2, name);
    }
    lua.set_field(lua::GLOBALS, c"skate3");
    0
}

/// # Safety
/// Called by Garry's Mod with a valid Lua state when the Lua state closes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gmod13_close(state: State) -> c_int {
    // Dropping the runtime closes its job channel; the worker exits on its own.
    if let Ok(mut runtime) = RUNTIME.lock() {
        *runtime = None;
    }
    if let Ok(api) = lua::api() {
        let lua = Lua { api, state };
        lua.push_nil();
        lua.set_field(lua::GLOBALS, c"skate3");
    }
    0
}
