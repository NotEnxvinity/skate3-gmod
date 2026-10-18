//! The skate session on its own thread, as the mashup runs it: jobs in,
//! latest state out. Lua never waits on the simulation.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, mpsc};

use glam::{Mat3, Mat4, Vec3};
use skate_bridge::bridge::{Controls, Session};
use skate_bridge::repro::{Driver, Event, Recording};
use skate_bridge::{collision, world};

/// Recordings of glitched rides kept in data/skate3/rides.
const KEEP_RIDES: usize = 5;

pub enum Job {
    Load {
        assets: PathBuf,
        bsp: Vec<u8>,
        extra: Vec<[Vec3; 3]>,
        live: Vec<crate::bsp::Live>,
    },
    Activate {
        pos: Vec3,
        yaw_degrees: f32,
        aspect: f32,
        goofy: bool,
    },
    Step {
        dt: f32,
        controls: Controls,
        aspect: f32,
    },
    Suspend,
    /// Objects on top of the map, such as spawned props, in Source units.
    Props { extra: Vec<[Vec3; 3]> },
    /// Where the map's moving brush entities (doors...) stand now.
    Doors { live: Vec<crate::bsp::Live> },
}

#[derive(Clone, Default)]
pub enum Status {
    #[default]
    Idle,
    /// Building the map's collision; the step it's on, for the console.
    Loading(&'static str),
    Ready,
    Failed(String),
}

/// What the skater looks like this tick, in Source space.
#[derive(Clone)]
pub struct Pose {
    pub pos: Vec3,
    pub forward: Vec3,
    pub up: Vec3,
    /// Units per second.
    pub velocity: Vec3,
    /// Metres per second, for the HUD.
    pub speed: f32,
    pub camera: Option<Camera>,
    pub state: String,
    /// Seconds of respawn invincibility left.
    pub invincible: f32,
    pub tick: u64,
    /// Every bone of the skater and board, in Source space.
    pub bones: Vec<(String, Mat4)>,
    pub score: Score,
}

/// The trick score, as the engine keeps it for its HUD.
pub type Score = skate_bridge::bridge::Score;

#[derive(Clone)]
pub struct Camera {
    pub pos: Vec3,
    pub forward: Vec3,
    pub up: Vec3,
    /// Source's horizontal field of view at 4:3.
    pub fov: f32,
}

#[derive(Default)]
pub struct Shared {
    pub status: Status,
    pub triangles: usize,
    /// Rails in Source units, for the debug overlay.
    pub rails: Vec<Vec<Vec3>>,
    pub pose: Option<Pose>,
    pub active: bool,
    /// Why the last ride stopped, if the simulation gave up on it. The map
    /// stays loaded, so the next activation starts a fresh ride.
    pub error: Option<String>,
    /// Counts collision swaps since the module loaded, so Lua knows when to
    /// fetch the rails again.
    pub revision: u32,
    /// Triangles of the objects laid over the map.
    pub props: usize,
}

pub struct Runtime {
    send: Option<mpsc::Sender<Job>>,
    worker: Option<std::thread::JoinHandle<()>>,
    pub shared: Arc<Mutex<Shared>>,
}

impl Runtime {
    pub fn start() -> Result<Self, String> {
        let (send, jobs) = mpsc::channel();
        let shared = Arc::new(Mutex::new(Shared::default()));
        let worker = Arc::clone(&shared);
        let worker = std::thread::Builder::new()
            .name("skate3".into())
            // The host decodes animation banks recursively.
            .stack_size(32 * 1024 * 1024)
            .spawn(move || run(jobs, worker))
            .map_err(|e| e.to_string())?;
        Ok(Self {
            send: Some(send),
            worker: Some(worker),
            shared,
        })
    }

    pub fn send(&self, job: Job) {
        // A send only fails once the worker died, which Shared already reports.
        if let Some(send) = &self.send {
            let _ = send.send(job);
        }
    }
}

impl Drop for Runtime {
    /// Waits for the worker: the game may unload this library right after,
    /// and no thread may still be running its code then.
    fn drop(&mut self) {
        self.send = None;
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn panic_message(panic: &(dyn std::any::Any + Send)) -> &str {
    panic
        .downcast_ref::<&str>()
        .copied()
        .or_else(|| panic.downcast_ref::<String>().map(String::as_str))
        .unwrap_or("no message")
}

/// A loaded map's collision in Skate space.
struct MapWorld {
    assets: PathBuf,
    /// The map plus whatever props are in it now.
    triangles: Vec<[[f32; 3]; 3]>,
    rails: Vec<Vec<[f32; 3]>>,
    /// The map alone, which prop collision is built on top of.
    base_triangles: Arc<Vec<[[f32; 3]; 3]>>,
    base_rails: Arc<Vec<Vec<[f32; 3]>>>,
}

/// Collision with props built off the simulation thread, ready to swap in.
struct Built {
    map: u64,
    prepared: Result<skate_bridge::bridge::PreparedCollision, String>,
    triangles: Vec<[[f32; 3]; 3]>,
    rails: Vec<Vec<[f32; 3]>>,
    props: usize,
}

/// The triangles of the moving brush entities where `live` has them now.
fn door_triangles(
    movers: &[(usize, Vec<Vec<[f32; 4]>>)],
    live: &[crate::bsp::Live],
) -> Vec<[Vec3; 3]> {
    let mut out = Vec::new();
    for planes in crate::bsp::placed(movers, live) {
        for face in collision::brush_faces(&planes) {
            for i in 1..face.len().saturating_sub(1) {
                out.push([face[0], face[i], face[i + 1]]);
            }
        }
    }
    out
}

/// Starts building the map with `extra` on top, on its own thread.
fn build_props(
    builder: skate_bridge::bridge::CollisionBuilder,
    map: &MapWorld,
    map_id: u64,
    extra: Vec<[Vec3; 3]>,
    done: mpsc::Sender<Built>,
) -> Option<std::thread::JoinHandle<()>> {
    let base_triangles = Arc::clone(&map.base_triangles);
    let base_rails = Arc::clone(&map.base_rails);
    std::thread::Builder::new()
        .name("skate3-props".into())
        .stack_size(32 * 1024 * 1024)
        .spawn(move || {
            skate_bridge::float_mode::pc();
            let built = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let added = world::extra(&base_triangles, &extra);
                let props = added.triangles.len();
                let mut triangles = base_triangles.to_vec();
                triangles.extend(added.triangles);
                let mut rails = base_rails.to_vec();
                // The engine counts rails in a u16; the map's own come first.
                let room = (u16::MAX as usize).saturating_sub(rails.len());
                rails.extend(added.rails.into_iter().take(room));
                let prepared = builder.build(triangles.clone(), rails.clone());
                Built {
                    map: map_id,
                    prepared,
                    triangles,
                    rails,
                    props,
                }
            }))
            .unwrap_or_else(|panic| Built {
                map: map_id,
                prepared: Err(format!(
                    "building prop collision crashed: {}",
                    panic_message(&*panic)
                )),
                triangles: Vec::new(),
                rails: Vec::new(),
                props: 0,
            });
            let _ = done.send(built);
        })
        .ok()
}

fn run(jobs: mpsc::Receiver<Job>, shared: Arc<Mutex<Shared>>) {
    // Simulate in the mode the engine was checked in, whatever the game uses.
    skate_bridge::float_mode::pc();
    let set = |f: &dyn Fn(&mut Shared)| {
        f(&mut shared.lock().unwrap_or_else(|e| e.into_inner()));
    };
    let stage = |step: &'static str| set(&|s| s.status = Status::Loading(step));
    let mut session: Option<Session> = None;
    let mut driver = Driver::default();
    // Everything the session was fed since it was built, saved when it
    // breaks so skate-headless can replay it.
    let mut recording: Option<Recording> = None;
    let mut recording_full = false;
    let mut last_input = Controls::default();
    let mut last_pos: Option<Vec3> = None;
    // The skater's last few states and the tick each began, for error reports.
    let mut states: Vec<(String, u64)> = Vec::new();
    // The current map's collision, kept to rebuild a session that broke.
    let mut map: Option<MapWorld> = None;
    // Set once the simulation failed: some of its state may be non-finite
    // beyond what a teleport resets, so the next ride starts a fresh session.
    let mut broken = false;
    // Prop collision: built on its own thread, one build at a time, with the
    // newest set of props waiting its turn. Builds for a map since replaced
    // are dropped.
    let (built_tx, built_rx) = mpsc::channel::<Built>();
    let mut building: Option<std::thread::JoinHandle<()>> = None;
    let mut pending: Option<Vec<[Vec3; 3]>> = None;
    // When the newest change came in: a build starts a moment after the last
    // of a burst (props and doors change together), not once for each.
    let mut pending_at = std::time::Instant::now();
    // What goes on top of the map: spawned and streamed props from Lua, and
    // the moving brush entities (their brushes in their own space, then
    // where they stand now). Any change builds the whole lot again.
    let mut props_extra: Vec<[Vec3; 3]> = Vec::new();
    let mut movers: Vec<(usize, Vec<Vec<[f32; 4]>>)> = Vec::new();
    let mut door_extra: Vec<[Vec3; 3]> = Vec::new();
    let mut map_id: u64 = 0;
    loop {
        let job = match jobs.recv_timeout(std::time::Duration::from_millis(50)) {
            Ok(job) => Some(job),
            Err(mpsc::RecvTimeoutError::Timeout) => None,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        };
        while let Ok(done) = built_rx.try_recv() {
            if let Some(h) = building.take() {
                let _ = h.join();
            }
            if done.map != map_id {
                continue;
            }
            let installed = match (done.prepared, session.as_mut()) {
                (Ok(prepared), Some(session)) => {
                    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        session.install_collision(prepared)
                    }))
                    .unwrap_or_else(|panic| {
                        Err(format!(
                            "swapping in prop collision crashed: {}",
                            panic_message(&*panic)
                        ))
                    })
                }
                (Ok(_), None) => Err("the map isn't loaded".into()),
                (Err(e), _) => Err(e),
            };
            match installed {
                Ok(()) => {
                    let rails: Vec<Vec<Vec3>> = done
                        .rails
                        .iter()
                        .map(|r| {
                            r.iter()
                                .map(|p| collision::from_skate(Vec3::from_array(*p)))
                                .collect()
                        })
                        .collect();
                    let count = done.triangles.len();
                    if let Some(map) = map.as_mut() {
                        // A ride recorded from here replays on the new collision.
                        recording = Some(Recording::new(done.triangles.clone(), done.rails.clone()));
                        recording_full = false;
                        map.triangles = done.triangles;
                        map.rails = done.rails;
                    }
                    set(&|s| {
                        s.triangles = count;
                        s.rails = rails.clone();
                        s.props = done.props;
                        s.revision = s.revision.wrapping_add(1);
                    });
                }
                Err(e) => eprintln!("[skate3] prop collision not swapped in: {e}"),
            }
        }
        if building.is_none()
            && pending_at.elapsed() >= std::time::Duration::from_millis(30)
            && let (Some(s), Some(m)) = (session.as_ref(), map.as_ref())
            && let Some(extra) = pending.take()
        {
            building = build_props(s.collision_builder(), m, map_id, extra, built_tx.clone());
        }
        let Some(job) = job else { continue };
        let job = match job {
            Job::Props { extra } => {
                props_extra = extra;
                pending = Some([props_extra.as_slice(), door_extra.as_slice()].concat());
                pending_at = std::time::Instant::now();
                None
            }
            Job::Doors { live } => {
                door_extra = door_triangles(&movers, &live);
                pending = Some([props_extra.as_slice(), door_extra.as_slice()].concat());
                pending_at = std::time::Instant::now();
                None
            }
            other => Some(other),
        };
        let Some(job) = job else { continue };
        if matches!(job, Job::Load { .. }) {
            // Props belong to the map they were placed in.
            map_id = map_id.wrapping_add(1);
            pending = None;
            props_extra.clear();
            door_extra.clear();
            movers.clear();
        }
        let riding = !matches!(job, Job::Load { .. });
        // A panic in the engine fails this job instead of silently killing
        // the thread, which would leave the map loading forever.
        let result: Result<(), String> =
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                match job {
                    Job::Load {
                        assets,
                        bsp,
                        extra,
                        live,
                    } => {
                        set(&|s| {
                            s.status = Status::Loading("reading the map");
                            s.active = false;
                            s.pose = None;
                        });
                        let solids = crate::bsp::parse_live(&bsp, &live)?;
                        drop(bsp);
                        movers = solids.movers;
                        let mut triangles = solids.triangles;
                        triangles.extend(extra);
                        stage("finding grind rails");
                        let built = world::build(&triangles, &solids.brushes);
                        drop(triangles);
                        let rails: Vec<Vec<Vec3>> = built
                            .rails
                            .iter()
                            .map(|r| {
                                r.iter()
                                    .map(|p| collision::from_skate(Vec3::from_array(*p)))
                                    .collect()
                            })
                            .collect();
                        let count = built.triangles.len();
                        map = Some(MapWorld {
                            assets: assets.clone(),
                            triangles: built.triangles.clone(),
                            rails: built.rails.clone(),
                            base_triangles: Arc::new(built.triangles.clone()),
                            base_rails: Arc::new(built.rails.clone()),
                        });
                        // A fresh session for every map, even one already
                        // running: a replay starts from a new session, so one
                        // whose collision was swapped mid-way couldn't be saved.
                        stage("loading the Skate 3 data");
                        broken = false;
                        session = None;
                        recording = None;
                        states.clear();
                        session = Some(Session::new(
                            &assets,
                            built.triangles,
                            built.rails,
                            [0.; 3],
                            0.,
                        )?);
                        driver = Driver::default();
                        recording = map
                            .as_ref()
                            .map(|m| Recording::new(m.triangles.clone(), m.rails.clone()));
                        recording_full = false;
                        set(&|s| {
                            s.status = Status::Ready;
                            s.triangles = count;
                            s.rails = rails.clone();
                            s.props = 0;
                            s.revision = s.revision.wrapping_add(1);
                        });
                    }
                    Job::Activate {
                        pos,
                        yaw_degrees,
                        aspect,
                        goofy,
                    } => {
                        if broken && let Some(map) = &map {
                            session = None;
                            recording = None;
                            session = Some(Session::new(
                                &map.assets,
                                map.triangles.clone(),
                                map.rails.clone(),
                                [0.; 3],
                                0.,
                            )?);
                            driver = Driver::default();
                            recording =
                                Some(Recording::new(map.triangles.clone(), map.rails.clone()));
                            recording_full = false;
                            broken = false;
                        }
                        let session = session.as_mut().ok_or("the map isn't loaded yet")?;
                        session.set_stance(goofy);
                        record(&mut recording, &mut recording_full, Event::Stance { goofy });
                        let spawn = collision::to_skate(pos).to_array();
                        let heading = yaw_degrees.to_radians() + std::f32::consts::FRAC_PI_2;
                        record(
                            &mut recording,
                            &mut recording_full,
                            Event::Activate {
                                spawn,
                                heading,
                                aspect,
                            },
                        );
                        last_pos = Some(pos);
                        let pose = driver.activate(session, spawn, heading, aspect)?;
                        let pose = convert(&pose)?;
                        set(&|s| {
                            s.active = true;
                            s.error = None;
                            s.pose = Some(pose.clone());
                        });
                    }
                    Job::Step {
                        dt,
                        controls,
                        aspect,
                    } => {
                        // Frames the game sent before it noticed the ride
                        // stopped: stepping the broken simulation would only
                        // fail again and bury the first error's report.
                        let Some(session) = session.as_mut().filter(|_| !broken) else {
                            return Ok(());
                        };
                        last_input = controls;
                        record(
                            &mut recording,
                            &mut recording_full,
                            Event::Step {
                                dt,
                                controls,
                                aspect,
                            },
                        );
                        let advanced = driver.step(session, dt, controls, aspect, |_| {})?;
                        if advanced {
                            let mut pose = convert(&session.pose())?;
                            last_pos = Some(pose.pos);
                            pose.score = session.score();
                            if states.last().is_none_or(|(state, _)| *state != pose.state) {
                                if states.len() == 6 {
                                    states.remove(0);
                                }
                                states.push((pose.state.clone(), pose.tick));
                            }
                            set(&|s| s.pose = Some(pose.clone()));
                        }
                    }
                    Job::Props { .. } | Job::Doors { .. } => {}
                    Job::Suspend => {
                        if let Some(session) = session.as_mut().filter(|_| !broken) {
                            record(&mut recording, &mut recording_full, Event::Suspend);
                            driver.suspend(session);
                        }
                        set(&|s| s.active = false);
                    }
                }
                Ok(())
            }))
            .unwrap_or_else(|panic| {
                Err(format!(
                    "the skate engine crashed: {}",
                    panic_message(&*panic)
                ))
            });
        if let Err(e) = result {
            if riding {
                broken = true;
                // Only this ride is lost; the map's collision is still good.
                let c = last_input;
                let history: Vec<String> = states
                    .iter()
                    .map(|(state, tick)| format!("{state}@{tick}"))
                    .collect();
                let mut e = format!(
                    "{e} (input: buttons {:04x}, triggers {:?}, left {:?}, right {:?}; states: {})",
                    c.buttons,
                    c.triggers,
                    c.left,
                    c.right,
                    history.join(" > ")
                );
                if let Some(p) = last_pos {
                    e += &format!(" at setpos {:.0} {:.0} {:.0}", p.x, p.y, p.z);
                }
                match (recording.take(), &map) {
                    (Some(rec), Some(map)) => match save_ride(&rec, &map.assets) {
                        Ok(name) => e += &format!("; ride saved as data/skate3/rides/{name}"),
                        Err(why) => e += &format!("; couldn't save the ride: {why}"),
                    },
                    // Every frame is one event, so a high frame rate fills
                    // the recording sooner.
                    _ if recording_full => {
                        e += "; ride not saved: it outgrew the recorder (fps_max 120 makes room)"
                    }
                    _ => e += "; ride not saved: this session wasn't recorded",
                }
                states.clear();
                if let Some(session) = session.as_mut() {
                    driver.suspend(session);
                }
                set(&|s| {
                    s.error = Some(e.clone());
                    s.active = false;
                    s.pose = None;
                });
            } else {
                set(&|s| {
                    s.status = Status::Failed(e.clone());
                    s.active = false;
                });
            }
        }
    }
    // No thread may still run this library's code once the game unloads it.
    if let Some(h) = building.take() {
        let _ = h.join();
    }
}

/// Adds to the recording, dropping it once it is full: a replay needs every
/// event from the session's start.
fn record(recording: &mut Option<Recording>, full: &mut bool, event: Event) {
    if let Some(rec) = recording
        && !rec.push(event)
    {
        *recording = None;
        *full = true;
    }
}

/// Writes a broken ride next to the converted data, as data/skate3/rides,
/// keeping only the newest few. Returns the file's name.
fn save_ride(rec: &Recording, assets: &std::path::Path) -> Result<String, String> {
    let dir = assets
        .parent()
        .ok_or("the data folder has no parent")?
        .join("rides");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let name = format!("ride-{secs}.sk3r");
    let mut file =
        std::io::BufWriter::new(std::fs::File::create(dir.join(&name)).map_err(|e| e.to_string())?);
    rec.write(&mut file).map_err(|e| e.to_string())?;
    std::io::Write::flush(&mut file).map_err(|e| e.to_string())?;
    let mut old: Vec<_> = std::fs::read_dir(&dir)
        .map_err(|e| e.to_string())?
        .filter_map(|f| f.ok().map(|f| f.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "sk3r"))
        .collect();
    old.sort();
    while old.len() > KEEP_RIDES {
        let _ = std::fs::remove_file(old.remove(0));
    }
    Ok(name)
}

/// Skate directions (Y up, metres) as Source directions (Z up).
fn dir(v: Vec3) -> Vec3 {
    Vec3::new(v.x, -v.z, v.y)
}

fn convert(p: &skate_bridge::bridge::Pose) -> Result<Pose, String> {
    let root = Mat4::from_cols_array(&p.root.to_cols_array());
    if !root.is_finite() {
        return Err("the skater's pose went non-finite".into());
    }
    let velocity = Vec3::from_array(p.velocity.to_array());
    let camera = p.camera.as_ref().map(|(pos, basis, fov)| {
        let basis = Mat3::from_cols_array(&basis.to_cols_array());
        Camera {
            pos: collision::from_skate(Vec3::from_array(pos.to_array())),
            forward: dir(basis.z_axis).normalize_or_zero(),
            up: dir(basis.y_axis).normalize_or_zero(),
            fov: source_fov(*fov),
        }
    });
    Ok(Pose {
        pos: collision::from_skate(root.w_axis.truncate()),
        forward: dir(root.z_axis.truncate()).normalize_or_zero(),
        up: dir(root.y_axis.truncate()).normalize_or_zero(),
        velocity: dir(velocity) / 0.0254,
        speed: velocity.length(),
        camera,
        state: p.state.clone(),
        invincible: p.invincible,
        tick: p.tick,
        // Bones are relative to the skater's root, as the mashup places them.
        bones: {
            let root = crate::skater::to_source(root);
            p.names
                .iter()
                .zip(&p.bones)
                .map(|(name, m)| {
                    let m = Mat4::from_cols_array(&m.to_cols_array());
                    (name.clone(), root * crate::skater::to_source(m))
                })
                .collect()
        },
        score: Score::default(),
    })
}

/// A vertical field of view as Source's horizontal one at a 4:3 aspect.
fn source_fov(vertical_degrees: f32) -> f32 {
    let half = (vertical_degrees.to_radians() * 0.5).tan() * (4. / 3.);
    (2. * half.atan()).to_degrees()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skate_directions_map_onto_source_axes() {
        // Skate's up is Source's up; skate +Z is Source -Y.
        assert_eq!(dir(Vec3::Y), Vec3::Z);
        assert_eq!(dir(Vec3::Z), -Vec3::Y);
        let p = Vec3::new(1., 2., 3.);
        assert!((dir(p) - collision::from_skate(p) * 0.0254).length() < 1e-5);
    }

    #[test]
    fn fov_converts_vertical_to_source_horizontal() {
        // 73.74 degrees vertical is 90 horizontal at 4:3.
        assert!((source_fov(73.739_8) - 90.).abs() < 0.01);
    }
}
