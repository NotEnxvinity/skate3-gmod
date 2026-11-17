//! Renders front-end sound events through the live engine on a real audio
//! cache into WAV files, to listen to what each one is.
//!
//! cargo run --release -p skate-aems --example fe_wav -- AUDIO_CACHE OUT_DIR [event names...]

use skate_aems::eac::BLOCK;
use skate_aems::live::{Engine, Frame, EMITTERS};
use std::io::Write;
use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 3 {
        eprintln!("usage: fe_wav AUDIO_CACHE OUT_DIR names...");
        std::process::exit(2);
    }
    let out_dir = Path::new(&args[1]);
    std::fs::create_dir_all(out_dir).unwrap();
    let mut engine = Engine::open(Path::new(&args[0]), None).expect("engine");
    for name in &args[2..] {
        let key = skate_aems::glue::seams::name_hash(name.as_bytes());
        for _ in 0..10 {
            engine.set_active(true);
            engine.set_frame(&Frame::default());
            let mut out = [[0f32; BLOCK]; EMITTERS];
            engine.render(&mut out);
        }
        let mut f = Frame::default();
        f.ui_events.push(key);
        engine.set_frame(&f);
        let mut samples: Vec<f32> = Vec::new();
        // 4 seconds, a game frame every 800 samples.
        let mut next_frame = 800usize;
        while samples.len() < 48_000 * 4 {
            if samples.len() >= next_frame {
                engine.set_frame(&Frame::default());
                next_frame += 800;
            }
            let mut out = [[0f32; BLOCK]; EMITTERS];
            engine.render(&mut out);
            for i in 0..BLOCK {
                samples.push(out[0][i] + out[1][i] + out[2][i]);
            }
        }
        let peak = samples.iter().fold(0f32, |m, x| m.max(x.abs()));
        let last = samples.iter().rposition(|x| x.abs() > 1e-4).unwrap_or(0);
        println!("{name}: peak {peak:.3}, sounds for {:.2} s", last as f32 / 48_000.0);
        let path = out_dir.join(format!("{name}.wav"));
        let mut w = std::fs::File::create(&path).unwrap();
        let data_len = (samples.len() * 2) as u32;
        w.write_all(b"RIFF").unwrap();
        w.write_all(&(36 + data_len).to_le_bytes()).unwrap();
        w.write_all(b"WAVEfmt ").unwrap();
        w.write_all(&16u32.to_le_bytes()).unwrap();
        w.write_all(&1u16.to_le_bytes()).unwrap();
        w.write_all(&1u16.to_le_bytes()).unwrap();
        w.write_all(&48_000u32.to_le_bytes()).unwrap();
        w.write_all(&96_000u32.to_le_bytes()).unwrap();
        w.write_all(&2u16.to_le_bytes()).unwrap();
        w.write_all(&16u16.to_le_bytes()).unwrap();
        w.write_all(b"data").unwrap();
        w.write_all(&data_len.to_le_bytes()).unwrap();
        for s in &samples {
            let v = (s.clamp(-1.0, 1.0) * 32767.0) as i16;
            w.write_all(&v.to_le_bytes()).unwrap();
        }
    }
}
