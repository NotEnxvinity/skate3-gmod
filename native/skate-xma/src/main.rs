//! skate-xma CLI (LGPL-2.1-or-later, see lib.rs).
//!
//!   skate-xma --version
//!   skate-xma --continuous FILE JOBS OUTDIR
//!       Drop-in for `xmadec --continuous`: one line per sound in JOBS,
//!       `NAME DATA_OFFSET SAMPLES CHANNELS RATE`; writes OUTDIR/NAME.xma16
//!       (big-endian PCM16, interleaved if stereo, whole 512-sample frames
//!       from the first). One decoder context per run, carried across jobs
//!       as in xmadec.
//!   skate-xma --snr FILE [DATA_OFFSET] OUT.xma16
//!       Standalone EA SNR stream whose header is at DATA_OFFSET (default 0;
//!       for a .grain file pass the u32 BE stored at byte 0).

use std::process::ExitCode;

use skate_xma::cli::{run_jobs, run_snr};

fn print(text: String) {
    println!("{text}");
}

fn usage() -> ExitCode {
    eprintln!(
        "usage: skate-xma --version\n       skate-xma --continuous FILE JOBS OUTDIR  (job: NAME OFFSET SAMPLES CHANNELS RATE)\n       skate-xma --snr FILE [DATA_OFFSET] OUT.xma16"
    );
    ExitCode::from(2)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut continuous = false;
    let mut snr = false;
    let mut rest: Vec<&str> = Vec::new();
    for a in &args {
        match a.as_str() {
            "--version" | "-V" => {
                println!("{}", skate_xma::VERSION_LINE);
                return ExitCode::SUCCESS;
            }
            "--continuous" => continuous = true,
            "--snr" => snr = true,
            s if s.starts_with("--") => return usage(),
            s => rest.push(s),
        }
    }
    let r = if snr {
        match rest.as_slice() {
            [file, out] => run_snr(file, 0, out).map(print),
            [file, off, out] => match off.parse::<usize>() {
                Ok(o) => run_snr(file, o, out).map(print),
                Err(_) => return usage(),
            },
            _ => return usage(),
        }
    } else if continuous {
        match rest.as_slice() {
            [file, jobs, outdir] => run_jobs(file, jobs, outdir).map(print),
            _ => return usage(),
        }
    } else {
        eprintln!("skate-xma: only --continuous and --snr decoding are implemented");
        return usage();
    };
    match r {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("skate-xma: {e}");
            ExitCode::FAILURE
        }
    }
}
