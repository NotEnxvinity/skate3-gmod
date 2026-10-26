//! The decoder's two jobs as functions, for the command line and for setup
//! to call inside the module (see gmod-skate/src/tools.rs). Each returns the
//! text the command prints.

pub fn run_jobs(file: &str, jobs: &str, outdir: &str) -> Result<String, String> {
    let data = std::fs::read(file).map_err(|e| format!("{file}: {e}"))?;
    let jobs = std::fs::read_to_string(jobs).map_err(|e| format!("{jobs}: {e}"))?;
    let mut dec = crate::Decoder::new();
    let mut done = 0usize;
    let mut notes: Vec<String> = Vec::new();
    for line in jobs.lines() {
        let mut it = line.split_whitespace();
        let (Some(name), Some(off), Some(samples), Some(ch), Some(rate)) = (it.next(), it.next(), it.next(), it.next(), it.next())
        else {
            continue;
        };
        let (Ok(off), Ok(samples), Ok(ch), Ok(_rate)) =
            (off.parse::<usize>(), samples.parse::<u32>(), ch.parse::<u32>(), rate.parse::<u32>())
        else {
            continue;
        };
        if ch > 2 {
            notes.push(format!("{name}: {ch} channels (multi-stream) not handled"));
            continue;
        }
        let pcm = dec.decode_sample(&data, off, samples, ch).map_err(|e| format!("{name}: {e}"))?;
        let path = format!("{outdir}/{name}.xma16");
        std::fs::write(&path, pcm.to_be_bytes()).map_err(|e| format!("{path}: {e}"))?;
        if pcm.av_errors != 0 {
            notes.push(format!("{name}: {} FFmpeg errors", pcm.av_errors));
        }
        done += 1;
    }
    notes.push(format!("{done} sounds"));
    Ok(notes.join("\n"))
}

pub fn run_snr(file: &str, offset: usize, out: &str) -> Result<String, String> {
    let data = std::fs::read(file).map_err(|e| format!("{file}: {e}"))?;
    if offset >= data.len() {
        return Err(format!("{file}: offset {offset} past end ({} bytes)", data.len()));
    }
    let (h, pcm) = crate::decode_snr(&data[offset..]).map_err(|e| format!("{file}: {e}"))?;
    std::fs::write(out, pcm.to_be_bytes()).map_err(|e| format!("{out}: {e}"))?;
    Ok(format!(
        "{file}: {} ch, {} Hz (header {} Hz), {} frames = {} samples, header samples {}{}",
        pcm.channels,
        pcm.sample_rate,
        h.sample_rate,
        pcm.frames,
        pcm.frames * crate::SAMPLES_PER_FRAME,
        h.samples,
        if pcm.av_errors != 0 { format!(", {} FFmpeg errors", pcm.av_errors) } else { String::new() }
    ))
}
