//! The skate session on its own thread, as the mashup runs it: jobs in,
//! latest state out. Lua never waits on the simulation.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, mpsc};

use glam::{Mat3, Mat4, Vec3};
use skate_bridge::bridge::{Controls, InputFrame, Session};
use skate_bridge::{collision, world};

/// The longest frame the simulation catches up on, as in the mashup.
const MAX_CATCH_UP: f32 = 0.15;

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
    Loading,
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
}

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

/// A loaded map's collision in Skate space.
struct MapWorld {
    assets: PathBuf,
    triangles: Vec<[[f32; 3]; 3]>,
    rails: Vec<Vec<[f32; 3]>>,
}

fn run(jobs: mpsc::Receiver<Job>, shared: Arc<Mutex<Shared>>) {
    let set = |f: &dyn Fn(&mut Shared)| {
        if let Ok(mut s) = shared.lock() {
            f(&mut s);
        }
    };
    let mut session: Option<Session> = None;
    let mut accumulated = 0f32;
    // XInput's packet number, advanced every frame as the mashup does.
    let mut packet = 0u32;
    let mut last_input = Controls::default();
    // The skater's last few states and the tick each began, for error reports.
    let mut states: Vec<(String, u64)> = Vec::new();
    // The current map's collision, kept to rebuild a session that broke.
    let mut map: Option<MapWorld> = None;
    // Set once the simulation failed: some of its state may be non-finite
    // beyond what a teleport resets, so the next ride starts a fresh session.
    let mut broken = false;
    while let Ok(job) = jobs.recv() {
        let riding = !matches!(job, Job::Load { .. });
        let result: Result<(), String> = (|| {
            match job {
                Job::Load { assets, bsp, extra } => {
                    set(&|s| {
                        s.status = Status::Loading;
                        s.active = false;
                        s.pose = None;
                    });
                    let solids = crate::bsp::parse(&bsp)?;
                    let mut triangles = solids.triangles;
                    triangles.extend(extra);
                    let built = world::build(&triangles, &solids.brushes);
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
                            let prepared = existing
                                .collision_builder()
                                .build(built.triangles, built.rails)?;
                            existing.install_collision(prepared)?;
                        }
                        None => {
                            broken = false;
                            session = None;
                            session = Some(Session::new(
                                &assets,
                                built.triangles,
                                built.rails,
                                [0.; 3],
                                0.,
                            )?);
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
                } => {
                    if broken && let Some(map) = &map {
                        session = None;
                        session = Some(Session::new(
                            &map.assets,
                            map.triangles.clone(),
                            map.rails.clone(),
                            [0.; 3],
                            0.,
                        )?);
                        broken = false;
                    }
                    let session = session.as_mut().ok_or("the map isn't loaded yet")?;
                    accumulated = 0.;
                    session.set_aspect_ratio(aspect);
                    let pose = session.activate(
                        collision::to_skate(pos).to_array(),
                        yaw_degrees.to_radians() + std::f32::consts::FRAC_PI_2,
                    )?;
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
                    let dt = dt.max(0.);
                    session.set_aspect_ratio(aspect);
                    // The game's own input path: sample the pad every frame,
                    // publish actions on each simulation tick.
                    packet = packet.wrapping_add(1);
                    last_input = controls;
                    session.collect(
                        InputFrame::from_pad(
                            controls.buttons,
                            controls.triggers,
                            controls.left,
                            controls.right,
                            packet,
                        ),
                        dt,
                    );
                    accumulated = (accumulated + dt).min(MAX_CATCH_UP);
                    let mut advanced = false;
                    // The native camera can change the simulation period.
                    while accumulated >= session.period() {
                        accumulated -= session.period();
                        session.advance()?;
                        advanced = true;
                    }
                    if advanced {
                        let pose = convert(&session.pose())?;
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
                    accumulated = 0.;
                    if let Some(session) = session.as_mut() {
                        session.suspend_input();
                    }
                    set(&|s| s.active = false);
                }
            }
            Ok(())
        })();
        if let Err(e) = result {
            if riding {
                broken = true;
                // Only this ride is lost; the map's collision is still good.
                let c = last_input;
                let history: Vec<String> = states
                    .iter()
                    .map(|(state, tick)| format!("{state}@{tick}"))
                    .collect();
                let e = format!(
                    "{e} (input: buttons {:04x}, triggers {:?}, left {:?}, right {:?}; states: {})",
                    c.buttons,
                    c.triggers,
                    c.left,
                    c.right,
                    history.join(" > ")
                );
                states.clear();
                accumulated = 0.;
                if let Some(session) = session.as_mut() {
                    session.suspend_input();
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
