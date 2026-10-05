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
    triangles: Vec<[[f32; 3]; 3]>,
    rails: Vec<Vec<[f32; 3]>>,
}

fn run(jobs: mpsc::Receiver<Job>, shared: Arc<Mutex<Shared>>) {
    let set = |f: &dyn Fn(&mut Shared)| {
        f(&mut shared.lock().unwrap_or_else(|e| e.into_inner()));
    };
    let stage = |step: &'static str| set(&|s| s.status = Status::Loading(step));
    let mut session: Option<Session> = None;
    let mut driver = Driver::default();
    // Everything the session was fed since it was built, saved when it
    // breaks so skate-headless can replay it.
    let mut recording: Option<Recording> = None;
    let mut last_input = Controls::default();
    let mut last_pos: Option<Vec3> = None;
    // The skater's last few states and the tick each began, for error reports.
    let mut states: Vec<(String, u64)> = Vec::new();
    // The current map's collision, kept to rebuild a session that broke.
    let mut map: Option<MapWorld> = None;
    // Set once the simulation failed: some of its state may be non-finite
    // beyond what a teleport resets, so the next ride starts a fresh session.
    let mut broken = false;
    while let Ok(job) = jobs.recv() {
        let riding = !matches!(job, Job::Load { .. });
        // A panic in the engine fails this job instead of silently killing
        // the thread, which would leave the map loading forever.
        let result: Result<(), String> =
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                match job {
                    Job::Load { assets, bsp, extra } => {
                        set(&|s| {
                            s.status = Status::Loading("reading the map");
                            s.active = false;
                            s.pose = None;
                        });
                        let solids = crate::bsp::parse(&bsp)?;
                        drop(bsp);
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
                        });
                        match session.as_mut().filter(|_| !broken) {
                            // A new map on a warm session swaps collision only.
                            Some(existing) => {
                                stage("swapping in the map's collision");
                                let prepared = existing
                                    .collision_builder()
                                    .build(built.triangles, built.rails)?;
                                existing.install_collision(prepared)?;
                                // A replay can't swap collision mid-session.
                                recording = None;
                            }
                            None => {
                                stage("loading the Skate 3 data");
                                broken = false;
                                session = None;
                                recording = None;
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
                            }
                        }
                        set(&|s| {
                            s.status = Status::Ready;
                            s.triangles = count;
                            s.rails = rails.clone();
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
                            broken = false;
                        }
                        let session = session.as_mut().ok_or("the map isn't loaded yet")?;
                        session.set_stance(goofy);
                        record(&mut recording, Event::Stance { goofy });
                        let spawn = collision::to_skate(pos).to_array();
                        let heading = yaw_degrees.to_radians() + std::f32::consts::FRAC_PI_2;
                        record(
                            &mut recording,
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
                        let Some(session) = session.as_mut() else {
                            return Ok(());
                        };
                        last_input = controls;
                        record(
                            &mut recording,
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
                    Job::Suspend => {
                        if let Some(session) = session.as_mut() {
                            record(&mut recording, Event::Suspend);
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
                if let (Some(rec), Some(map)) = (recording.take(), &map) {
                    match save_ride(&rec, &map.assets) {
                        Ok(name) => e += &format!("; ride saved as data/skate3/rides/{name}"),
                        Err(why) => e += &format!("; couldn't save the ride: {why}"),
                    }
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
}

/// Adds to the recording, dropping it once it is full: a replay needs every
/// event from the session's start.
fn record(recording: &mut Option<Recording>, event: Event) {
    if let Some(rec) = recording
        && !rec.push(event)
    {
        *recording = None;
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
