//! Milestone 1: prove the Skate 3 host runs on Linux without Gmod.
//!
//!   skate-headless [--assets <converted data dir>] [--ticks N]
//!   skate-headless --assets <dir> --replay <ride.sk3r>
//!   skate-headless --assets <dir> --soak <seconds>
//!
//! Builds a test park (floor plus a ledge) from Source-style brushes, finds its
//! grind rails, and with `--assets` drops a skater on it and ticks the
//! simulation, printing where the skater ends up.
//!
//! `--replay` instead plays back a ride the mod saved when it glitched
//! (garrysmod/data/skate3/rides), to see whether and where it breaks again.
//!
//! `--soak` rides the test park for that long at 60 frames a second, driven
//! exactly as the game drives it, and prints the process's memory as it goes,
//! to tell a leak in the simulation from one in the game.

use glam::Vec3;
use skate_bridge::bridge::{Controls, Session};
use skate_bridge::repro::{Driver, Event, Recording};
use skate_bridge::{collision, world};

fn main() {
    let mut assets = None;
    let mut ticks = 300u32;
    let mut replay = None;
    let mut soak = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--assets" => assets = args.next(),
            "--ticks" => ticks = args.next().and_then(|n| n.parse().ok()).unwrap_or(ticks),
            "--replay" => replay = args.next(),
            "--soak" => soak = args.next().and_then(|n| n.parse::<u32>().ok()),
            _ => {
                eprintln!(
                    "usage: skate-headless [--assets <dir>] [--ticks N] [--replay <ride.sk3r>] [--soak <seconds>]"
                );
                std::process::exit(2);
            }
        }
    }

    if let Some(ride) = replay {
        let Some(assets) = assets else {
            eprintln!("--replay needs --assets <converted data dir>");
            std::process::exit(2);
        };
        let result = std::thread::Builder::new()
            .stack_size(32 * 1024 * 1024)
            .spawn(move || play(&assets, &ride))
            .expect("spawn skate thread")
            .join()
            .expect("skate thread panicked");
        if let Err(e) = result {
            eprintln!("skate: {e}");
            std::process::exit(1);
        }
        return;
    }

    let park = world::build(
        &[],
        &[
            world::box_brush(Vec3::new(-2048., -2048., -16.), Vec3::new(2048., 2048., 0.)),
            world::box_brush(Vec3::new(256., -16., 0.), Vec3::new(768., 16., 16.)),
        ],
    );
    println!(
        "park: {} triangles, {} walkable edges, {} lips, {} runs, {} rails",
        park.triangles.len(),
        park.census.candidates,
        park.census.lips,
        park.census.runs,
        park.census.rails,
    );

    let Some(assets) = assets else {
        println!("no --assets given; skipping the simulation");
        return;
    };
    if let Some(seconds) = soak {
        let result = std::thread::Builder::new()
            .stack_size(32 * 1024 * 1024)
            .spawn(move || run_soak(&assets, park, seconds))
            .expect("spawn skate thread")
            .join()
            .expect("skate thread panicked");
        if let Err(e) = result {
            eprintln!("skate: {e}");
            std::process::exit(1);
        }
        return;
    }
    // The host decodes animation banks recursively; give it the stack the
    // mashup gives its skate thread.
    let result = std::thread::Builder::new()
        .stack_size(32 * 1024 * 1024)
        .spawn(move || simulate(&assets, park, ticks))
        .expect("spawn skate thread")
        .join()
        .expect("skate thread panicked");
    if let Err(e) = result {
        eprintln!("skate: {e}");
        std::process::exit(1);
    }
}

/// XInput's A button, as the host's raw pad packet carries it.
const BUTTON_A: u16 = 0x1000;
/// Ticks between pushes, and how long A is held for each.
const PUSH_EVERY: u32 = 45;
const PUSH_HOLD: u32 = 6;

fn simulate(assets: &str, park: world::World, ticks: u32) -> Result<(), String> {
    let start = std::time::Instant::now();
    let mut session = Session::new(
        std::path::Path::new(assets),
        park.triangles,
        park.rails,
        [0.; 3],
        0.,
    )?;
    println!(
        "session loaded in {}ms, period {:.4}s",
        start.elapsed().as_millis(),
        session.period()
    );
    let pose = session.activate(collision::to_skate(Vec3::ZERO).to_array(), 0.)?;
    report("spawned", &pose);
    // Skate 3 pushes off A, not the stick: tap it like a player would.
    let start = std::time::Instant::now();
    let mut top_speed = 0f32;
    for tick in 1..=ticks {
        let controls = Controls {
            buttons: if tick % PUSH_EVERY < PUSH_HOLD {
                BUTTON_A
            } else {
                0
            },
            ..Controls::default()
        };
        session.tick(controls)?;
        top_speed = top_speed.max(session.pose().velocity.length());
        if tick % 60 == 0 || tick == ticks {
            report(&format!("tick {tick}"), &session.pose());
        }
    }
    println!("top speed {top_speed:.2} m/s");
    let elapsed = start.elapsed().as_secs_f64();
    println!(
        "{ticks} ticks in {:.1}ms ({:.0} ticks/s, {:.1}x realtime)",
        elapsed * 1000.,
        f64::from(ticks) / elapsed,
        f64::from(ticks) * f64::from(session.period()) / elapsed,
    );
    Ok(())
}

/// Resident memory in MB, from /proc (Linux only).
fn resident_mb() -> Option<f64> {
    let statm = std::fs::read_to_string("/proc/self/statm").ok()?;
    let pages = statm.split_whitespace().nth(1)?.parse::<f64>().ok()?;
    Some(pages * 4096. / (1024. * 1024.))
}

/// Rides the park through the Driver, as the game does every frame, and
/// prints memory every ten seconds of riding.
fn run_soak(assets: &str, park: world::World, seconds: u32) -> Result<(), String> {
    let mut session = Session::new(
        std::path::Path::new(assets),
        park.triangles,
        park.rails,
        [0.; 3],
        0.,
    )?;
    let mut driver = Driver::default();
    driver.activate(
        &mut session,
        collision::to_skate(Vec3::ZERO).to_array(),
        0.,
        16. / 9.,
    )?;
    let mb = |label: &str| match resident_mb() {
        Some(mb) => println!("{label}: {mb:.0} MB"),
        None => println!("{label}: memory unknown"),
    };
    mb("activated");
    let frames = seconds * 60;
    for frame in 1..=frames {
        let controls = Controls {
            buttons: if frame % PUSH_EVERY < PUSH_HOLD {
                BUTTON_A
            } else {
                0
            },
            ..Controls::default()
        };
        driver.step(&mut session, 1. / 60., controls, 16. / 9., |_| {})?;
        // What the game reads back every frame.
        let pose = session.pose();
        let _score = session.score();
        if frame % 600 == 0 {
            mb(&format!("{}s, {}", frame / 60, pose.state));
        }
    }
    Ok(())
}

fn report(label: &str, pose: &skate_bridge::bridge::Pose) {
    let at = collision::from_skate(Vec3::from_array(pose.root.w_axis.truncate().to_array()));
    println!(
        "{label}: source pos ({:.1}, {:.1}, {:.1}), speed {:.2} m/s, {} bones, state {}",
        at.x,
        at.y,
        at.z,
        pose.velocity.length(),
        pose.bones.len(),
        pose.state,
    );
}

/// Replays a saved ride on a fresh session, as the mod fed it.
fn play(assets: &str, path: &str) -> Result<(), String> {
    let mut file =
        std::io::BufReader::new(std::fs::File::open(path).map_err(|e| format!("{path}: {e}"))?);
    let rec = Recording::read(&mut file).map_err(|e| format!("{path}: {e}"))?;
    let steps = rec
        .events
        .iter()
        .filter(|e| matches!(e, Event::Step { .. }))
        .count();
    println!(
        "ride: {} triangles, {} rails, {} events ({steps} frames)",
        rec.triangles.len(),
        rec.rails.len(),
        rec.events.len()
    );
    let mut session = Session::new(
        std::path::Path::new(assets),
        rec.triangles,
        rec.rails,
        [0.; 3],
        0.,
    )?;
    let mut driver = Driver::default();
    let mut state = String::new();
    let mut frame = 0usize;
    // Simulation ticks run so far, to aim SKATE3_AUDIT_OFFBOARD_TICKS at the
    // tick that breaks.
    let mut ticks = 0u64;
    for (i, event) in rec.events.iter().enumerate() {
        let result = match *event {
            Event::Activate {
                spawn,
                heading,
                aspect,
            } => driver
                .activate(&mut session, spawn, heading, aspect)
                .map(|pose| {
                    report(&format!("event {i}: activated"), &pose);
                }),
            Event::Step {
                dt,
                controls,
                aspect,
            } => {
                frame += 1;
                driver
                    .step(&mut session, dt, controls, aspect, |_| ticks += 1)
                    .and_then(|_| {
                        let pose = session.pose();
                        if !pose.root.is_finite() {
                            return Err("the skater's pose went non-finite".into());
                        }
                        if pose.state != state {
                            state = pose.state.clone();
                            report(&format!("frame {frame}"), &pose);
                        }
                        Ok(())
                    })
            }
            Event::Stance { goofy } => {
                session.set_stance(goofy);
                Ok(())
            }
            Event::Suspend => {
                driver.suspend(&mut session);
                println!("event {i}: suspended");
                Ok(())
            }
        };
        if let Err(e) = result {
            println!("BROKE at event {i} (frame {frame}, tick {ticks}): {e}");
            return Ok(());
        }
    }
    println!("replayed the whole ride without a glitch");
    Ok(())
}
