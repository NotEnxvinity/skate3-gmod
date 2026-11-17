//! Plays front-end sound events through the live engine on a real audio
//! cache and says what came out, the way the game posts them (the session
//! marker's: ride stops, a new ride starts, the event rides its first frame).
//!
//! cargo run --release -p skate-aems --example fe_probe -- <audio-cache> [event names...]

use skate_aems::eac::BLOCK;
use skate_aems::live::ui_sounds::EVENT_CLASS;
use skate_aems::live::{Engine, Frame, EMITTERS};
use std::path::Path;

fn name_hash(name: &str) -> u64 {
    skate_aems::glue::seams::name_hash(name.as_bytes())
}

fn main() {
    let mut args = std::env::args().skip(1);
    let Some(cache) = args.next() else {
        eprintln!("usage: fe_probe <audio-cache> [event names...]");
        std::process::exit(2);
    };
    let mut names: Vec<String> = args.collect();
    if names.is_empty() {
        names = ["multiplyer_2", "cellphone_goto_marker", "cellphone_marker_error"].map(String::from).to_vec();
    }
    let mut engine = match Engine::open(Path::new(&cache), None) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("engine didn't open: {e}");
            std::process::exit(1);
        }
    };
    println!("engine: {}", engine.summary());
    if let Err(e) = engine.driver.ensure_live_ready() {
        println!("not live-ready: {e}");
    }
    for name in &names {
        let key = name_hash(name);
        let t = &engine.driver.tuning;
        let c = t.collection(EVENT_CLASS, key);
        println!("\n== {name} (0x{key:016x}): record {}", if c == 0 { "MISSING".to_string() } else { format!("at 0x{c:08x}") });
        for (label, restart) in [("mid-ride", false), ("after a ride restart", true)] {
            let mut warm = Frame::default();
            warm.fields.clear();
            for _ in 0..30 {
                engine.set_active(true);
                engine.set_frame(&warm);
                render(&mut engine, 800);
            }
            if restart {
                engine.set_active(false);
                engine.set_active(true);
            }
            let mut f = Frame::default();
            f.ui_events.push(key);
            engine.set_frame(&f);
            let mut energy = [0f64; EMITTERS];
            let mut first = None;
            for frame in 0..180 {
                if frame > 0 {
                    engine.set_frame(&Frame::default());
                }
                let e = render(&mut engine, 800);
                for i in 0..EMITTERS {
                    energy[i] += e[i];
                }
                if first.is_none() && e.iter().sum::<f64>() > 1e-9 {
                    first = Some(frame);
                }
            }
            println!("  {label}: energy board {:.3} body {:.3} speed {:.3}; first heard on frame {:?}", energy[0], energy[1], energy[2], first);
        }
    }
    println!("\nproblems:");
    for p in engine.problems() {
        println!("  {p}");
    }
}

/// About `samples` of audio; energy per emitter.
fn render(engine: &mut Engine, samples: usize) -> [f64; EMITTERS] {
    let mut e = [0f64; EMITTERS];
    let mut n = 0;
    while n < samples {
        let mut out = [[0f32; BLOCK]; EMITTERS];
        engine.render(&mut out);
        for i in 0..EMITTERS {
            e[i] += out[i].iter().map(|x| f64::from(*x).powi(2)).sum::<f64>();
        }
        n += BLOCK;
    }
    e
}
