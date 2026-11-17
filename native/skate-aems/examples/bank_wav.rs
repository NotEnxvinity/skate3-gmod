//! Writes every sample of the named splice banks in an audio cache as WAV
//! files, to find a sound by ear.
//!
//! cargo run --release -p skate-aems --example bank_wav -- AUDIO_CACHE OUT_DIR BANK_STEMS...

use skate_aems::eac::snr::Snr;
use skate_aems::splice::Bank;
use std::io::Write;
use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 3 {
        eprintln!("usage: bank_wav AUDIO_CACHE OUT_DIR BANK_STEMS...");
        std::process::exit(2);
    }
    let cache = Path::new(&args[0]);
    let out = Path::new(&args[1]);
    std::fs::create_dir_all(out).unwrap();
    for stem in &args[2..] {
        let raw = match std::fs::read(cache.join("raw/audiofiles").join(format!("{stem}.bnk"))) {
            Ok(r) => r,
            Err(e) => {
                println!("{stem}: {e}");
                continue;
            }
        };
        let bank = match Bank::parse(raw) {
            Ok(b) => b,
            Err(e) => {
                println!("{stem}: {e}");
                continue;
            }
        };
        println!("{stem}: {} sounds, {} samples", bank.sounds.len(), bank.samples.len());
        for (i, e) in bank.samples.iter().enumerate() {
            let at = bank.data_at + e.snr as usize;
            let snr = Snr::parse(&bank.raw[at..]);
            let pcm_path = cache.join("pcm/audiofiles").join(format!("{stem}_{i}.xma16"));
            let Ok(data) = std::fs::read(&pcm_path) else {
                println!("  {i}: no decoded pcm");
                continue;
            };
            let ch = snr.channels.max(1) as u16;
            let rate = snr.rate.round().max(8000.0) as u32;
            let pcm: Vec<i16> = data.chunks_exact(2).map(|b| i16::from_be_bytes([b[0], b[1]])).collect();
            let secs = pcm.len() as f32 / ch as f32 / rate as f32;
            println!("  {i}: {ch} ch, {rate} Hz, {secs:.2} s{}", if snr.looped { ", loops" } else { "" });
            let path = out.join(format!("{stem}_{i:03}_{secs:.1}s{}.wav", if snr.looped { "_loop" } else { "" }));
            let mut w = std::fs::File::create(&path).unwrap();
            let len = (pcm.len() * 2) as u32;
            w.write_all(b"RIFF").unwrap();
            w.write_all(&(36 + len).to_le_bytes()).unwrap();
            w.write_all(b"WAVEfmt ").unwrap();
            w.write_all(&16u32.to_le_bytes()).unwrap();
            w.write_all(&1u16.to_le_bytes()).unwrap();
            w.write_all(&ch.to_le_bytes()).unwrap();
            w.write_all(&rate.to_le_bytes()).unwrap();
            w.write_all(&(rate * 2 * ch as u32).to_le_bytes()).unwrap();
            w.write_all(&(2 * ch).to_le_bytes()).unwrap();
            w.write_all(&16u16.to_le_bytes()).unwrap();
            w.write_all(b"data").unwrap();
            w.write_all(&len.to_le_bytes()).unwrap();
            for s in &pcm {
                w.write_all(&s.to_le_bytes()).unwrap();
            }
        }
    }
}
