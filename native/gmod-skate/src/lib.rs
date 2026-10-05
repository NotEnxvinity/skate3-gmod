//! `gmcl_skate3`: the Skate 3 simulation as a Garry's Mod client module,
//! loaded with `require("skate3")` the way G64 loads libsm64.
//!
//! Everything Lua calls returns immediately: map loading and simulation run on
//! a worker thread, and Lua reads back the latest state.

mod bsp;
mod input;
mod lua;
mod pin;
mod runtime;
mod skater;

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
            .map(|s| {
                (
                    s.status.clone(),
                    s.triangles,
                    s.rails.len(),
                    s.active,
                    s.error.clone(),
                )
            })
            .map_err(|_| ())
    }) {
        let (state, triangles, rails, active, ride_error) = s;
        let (name, error) = match state {
            Status::Idle => ("idle", None),
            Status::Loading => ("loading", None),
            Status::Ready => ("ready", ride_error),
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
        return lua.fail("Activate expects x, y, z, yaw[, aspect[, goofy]]");
    };
    let aspect = lua.number(5).unwrap_or(16. / 9.) as f32;
    let goofy = lua.number(6).unwrap_or(1.) != 0.;
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
        // A new ride: the last one's error no longer applies.
        if let Ok(mut s) = r.shared.lock() {
            s.error = None;
        }
        r.send(Job::Activate {
            pos: Vec3::new(x as f32, y as f32, z as f32),
            yaw_degrees: yaw as f32,
            aspect,
            goofy,
        })
    });
    lua.push_bool(true);
    1
});

lua_fn!(step, |lua| {
    let dt = lua.number(1).unwrap_or(0.) as f32;
    let aspect = lua.number(2).unwrap_or(16. / 9.) as f32;
    let mut controls = match input::poll() {
        Ok(pad) => pad.controls,
        Err(e) => return lua.fail(&format!("gamepad: {e}")),
    };
    // Buttons Lua presses on the player's behalf, such as Y to step off.
    controls.buttons |= lua.number(3).unwrap_or(0.) as u16;
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
    // Only the bones Lua draws or retargets; the rest are fingers and faces.
    if let Ok(wanted) = WANTED_BONES.lock() {
        lua.new_table();
        for (name, m) in p.bones.iter().filter(|(n, _)| wanted.contains(n)) {
            push_matrix(&lua, m);
            lua.set_field(
                -2,
                &std::ffi::CString::new(name.as_str()).unwrap_or_default(),
            );
        }
        lua.set_field(-2, c"bones");
    }
    let score = &p.score;
    lua.new_table();
    lua.push_str(&score.trick);
    lua.set_field(-2, c"trick");
    for (name, value) in [
        (c"sequence", score.sequence),
        (c"line", score.line),
        (c"banked", score.banked),
        (c"multiplier", score.multiplier),
        (c"timer", score.line_timer),
    ] {
        lua.push_number(f64::from(value));
        lua.set_field(-2, name);
    }
    lua.push_bool(score.active);
    lua.set_field(-2, c"active");
    lua.set_field(-2, c"score");
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

/// The skater's bones the playermodel retarget reads.
const BODY_BONES: [&str; 23] = [
    "HIPS",
    "SPINE",
    "SPINE1",
    "SPINE2",
    "SPINE3",
    "NECK",
    "HEAD",
    "LEFTSHOULDER",
    "LEFTARM",
    "LEFTFOREARM",
    "LEFTHAND",
    "RIGHTSHOULDER",
    "RIGHTARM",
    "RIGHTFOREARM",
    "RIGHTHAND",
    "LEFTUPLEG",
    "LEFTLEG",
    "LEFTFOOT",
    "LEFTTOEBASE",
    "RIGHTUPLEG",
    "RIGHTLEG",
    "RIGHTFOOT",
    "RIGHTTOEBASE",
];

/// Bones `GetPose` returns: the body's, plus whichever carry board parts.
static WANTED_BONES: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// A matrix as the 12 numbers of its top three rows, for Lua's `Matrix`.
fn push_matrix(lua: &Lua, m: &glam::Mat4) {
    lua.new_table();
    let rows = m.transpose().to_cols_array();
    for (i, v) in rows[..12].iter().enumerate() {
        lua.push_number(f64::from(*v));
        lua.set_index(-2, i as c_int + 1);
    }
}

/// The path below `garrysmod/data`, which Lua's file and material functions
/// can reach, if `path` is under it.
fn data_relative(path: &Path) -> Option<String> {
    let text = path.to_string_lossy().replace('\\', "/");
    let at = text.to_ascii_lowercase().rfind("garrysmod/data/")?;
    Some(
        text[at + "garrysmod/data/".len()..]
            .trim_end_matches('/')
            .to_owned(),
    )
}

lua_fn!(get_skater, |lua| {
    let Some(assets) = ASSETS.lock().ok().and_then(|a| a.clone()) else {
        return lua.fail("call skate3.Init first");
    };
    let skater = match skater::load(&assets) {
        Ok(s) => s,
        Err(e) => return lua.fail(&e),
    };
    if let Ok(mut wanted) = WANTED_BONES.lock() {
        wanted.clear();
        wanted.extend(BODY_BONES.iter().map(|s| s.to_string()));
        for part in &skater.parts {
            if !wanted.contains(&part.bone) {
                wanted.push(part.bone.clone());
            }
        }
    }
    lua.new_table();
    lua.new_table();
    for (i, part) in skater.parts.iter().enumerate() {
        lua.new_table();
        lua.push_str(&part.bone);
        lua.set_field(-2, c"bone");
        lua.push_str(&part.slot);
        lua.set_field(-2, c"slot");
        lua.new_table();
        for (j, c) in part.tint.iter().enumerate() {
            lua.push_number(f64::from(*c));
            lua.set_index(-2, j as c_int + 1);
        }
        lua.set_field(-2, c"tint");
        lua.new_table();
        for (j, v) in part.vertices.iter().enumerate() {
            lua.push_number(f64::from(*v));
            lua.set_index(-2, j as c_int + 1);
        }
        lua.set_field(-2, c"vertices");
        lua.set_index(-2, i as c_int + 1);
    }
    lua.set_field(-2, c"parts");
    lua.new_table();
    for (name, m) in &skater.bind {
        push_matrix(&lua, m);
        lua.set_field(
            -2,
            &std::ffi::CString::new(name.as_str()).unwrap_or_default(),
        );
    }
    lua.set_field(-2, c"bind");
    // The setup script's per-slot textures, reachable as "../data/<dir>/<slot>_base_color.png".
    if let Some(dir) = data_relative(&assets) {
        lua.push_str(&format!("{dir}/private/default_skater/textures/materials"));
        lua.set_field(-2, c"textures");
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

// The pad exactly as the simulation receives it, for checking that a
// controller's buttons get through Steam Input.
lua_fn!(get_input, |lua| {
    let pad = match input::poll() {
        Ok(pad) => pad,
        Err(e) => return lua.fail(&format!("gamepad: {e}")),
    };
    let c = pad.controls;
    lua.new_table();
    for (name, value) in [
        (c"buttons", f64::from(c.buttons)),
        (c"lt", f64::from(c.triggers[0])),
        (c"rt", f64::from(c.triggers[1])),
        (c"lx", f64::from(c.left[0])),
        (c"ly", f64::from(c.left[1])),
        (c"rx", f64::from(c.right[0])),
        (c"ry", f64::from(c.right[1])),
    ] {
        lua.push_number(value);
        lua.set_field(-2, name);
    }
    if let Some(name) = pad.name {
        lua.push_str(&name);
        lua.set_field(-2, c"pad");
    }
    1
});

lua_fn!(version, |lua| {
    lua.push_str(&match option_env!("GITHUB_RUN_NUMBER") {
        Some(run) => format!("{} (build {run})", env!("CARGO_PKG_VERSION")),
        None => env!("CARGO_PKG_VERSION").to_owned(),
    });
    1
});

/// The game process's resident memory in MB, for the health line: from
/// /proc on Linux, and through Wine's Z: drive under Proton. Nil elsewhere.
lua_fn!(memory, |lua| {
    let statm = ["/proc/self/statm", "Z:\\proc\\self\\statm"]
        .iter()
        .find_map(|path| std::fs::read_to_string(path).ok());
    let resident = statm.and_then(|s| s.split_whitespace().nth(1)?.parse::<f64>().ok());
    match resident {
        Some(pages) => lua.push_number(pages * 4096. / (1024. * 1024.)),
        None => lua.push_nil(),
    }
    1
});

/// # Safety
/// Called by Garry's Mod with a valid Lua state when the module is required.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gmod13_open(state: State) -> c_int {
    static PINNED: std::sync::Once = std::sync::Once::new();
    PINNED.call_once(|| {
        pin::pin();
    });
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
        (c"GetInput", get_input),
        (c"GetSkater", get_skater),
        (c"Version", version),
        (c"Memory", memory),
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_the_data_folder_on_linux_and_proton() {
        let linux = Path::new(
            "/home/deck/.local/share/Steam/steamapps/common/GarrysMod/garrysmod/data/skate3/assets",
        );
        assert_eq!(data_relative(linux).as_deref(), Some("skate3/assets"));
        let proton = Path::new(r"\\?\Z:\home\deck\GarrysMod\garrysmod\data\skate3\assets\");
        assert_eq!(data_relative(proton).as_deref(), Some("skate3/assets"));
        assert_eq!(data_relative(Path::new("/elsewhere/assets")), None);
    }
}
