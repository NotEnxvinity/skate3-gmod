//! Skate 3's own sounds, played by a port of its audio scripts instead of
//! Source's sound system.
//!
//! The simulation publishes the audio-relevant skater state after every tick
//! (`on_tick`); a dedicated thread runs the AEMS sound scripts from it
//! (`skate_aems::live::Engine`: the class handlers, the AEMS world at its
//! 30 Hz control rate, every voice through EA Audio Core's dry chain),
//! renders 256-frame blocks at 48 kHz and plays them on the machine's default
//! output device. Nothing here waits on audio: the hand-off is a bounded,
//! ordered queue written once per tick, and the output callback only reads a
//! ring of finished samples.
//!
//! Adapted from SK8V's skatev-runtime/src/audio.rs (Apache-2.0,
//! https://github.com/becaring/SK8V), which hands the rendered streams to
//! GTA's mixer where this one opens its own output. Source's volume slider and
//! its 3D placement don't apply to it: the streams are dry and centred, and
//! `skate3_volume` scales them.
//!
//! The cache it plays from is built by setup (audio_cache.py).

use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread::JoinHandle;
use std::time::Duration;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, SampleFormat, SizedSample, StreamConfig};
use skate_aems::live::{self, EMITTERS};

use crate::audio_map as map;

pub const SAMPLE_RATE: u32 = 48_000;
const BLOCK: usize = 256;
/// Finished audio kept ahead of the output device (43 ms).
const LEAD_FRAMES: usize = 2048;
/// Gameplay frames that may wait for the audio clock; older ones are applied
/// at once.
const MAX_BACKLOG: usize = 2;
/// Ticks that may queue before the audio gives up (a stalled engine).
const MAX_PENDING: usize = 240;

pub const STATE_LOADING: u32 = 1;
pub const STATE_READY: u32 = 2;
pub const STATE_ERROR: u32 = 3;

/// The audio-relevant state the simulation publishes after each tick.
#[derive(Clone, Default)]
struct Published {
    /// A skate session is active.
    active: bool,
    /// Skate's game variables for the sound handlers.
    frame: live::Frame,
}

/// Preserves one-tick edges even when the producer runs between audio blocks.
/// An overflow is an error rather than silently erasing gameplay events.
#[derive(Default)]
struct Publications {
    pending: VecDeque<Published>,
    overflow: bool,
}

impl Publications {
    fn push(&mut self, p: Published) {
        if self.pending.len() == MAX_PENDING {
            self.overflow = true;
            return;
        }
        self.pending.push_back(p);
    }
}

struct Shared {
    published: Mutex<Publications>,
    /// Finished interleaved stereo samples at `SAMPLE_RATE`.
    out: Mutex<VecDeque<f32>>,
    /// `f32` bits.
    volume: AtomicU32,
    stop: AtomicBool,
    state: AtomicU32,
    voices: AtomicU32,
    underruns: AtomicU32,
    frames: AtomicU64,
    /// Whether anything was sounding at the newest block.
    sounding: AtomicBool,
    message: Mutex<String>,
    /// What is sounding, per class, refreshed four times a second.
    debug: Mutex<String>,
}

struct Running {
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
}

static ENGINE: OnceLock<Mutex<Option<Running>>> = OnceLock::new();

fn slot() -> &'static Mutex<Option<Running>> {
    ENGINE.get_or_init(|| Mutex::new(None))
}

fn current() -> Option<Arc<Shared>> {
    slot().lock().ok()?.as_ref().map(|r| Arc::clone(&r.shared))
}

fn set_message(s: &Shared, m: impl Into<String>) {
    if let Ok(mut g) = s.message.lock() {
        *g = m.into();
    }
}

/// Whether the engine is ready and playing: Lua keeps its own sounds quiet
/// while it is.
pub fn ready() -> bool {
    current().is_some_and(|s| s.state.load(Ordering::Relaxed) == STATE_READY)
}

/// Called after every simulation tick: reads the session's audio state
/// (read-only) and queues it for the audio thread.
pub fn on_tick(session: &skate_bridge::bridge::Session, state: &mut map::State) {
    let Some(s) = current().filter(|s| s.state.load(Ordering::Relaxed) != STATE_ERROR) else {
        return;
    };
    let frame = state.frame(session);
    if let Ok(mut g) = s.published.lock() {
        g.push(Published {
            active: true,
            frame,
        });
    }
}

/// Marks skating inactive: voices end and their tails play out.
pub fn deactivate() {
    if let Some(s) = current()
        && let Ok(mut g) = s.published.lock()
    {
        g.push(Published::default());
    }
}

/// Starts the engine on the prepared cache at `cache`. A running one is
/// stopped first. Returns at once: loading runs on the audio thread, and
/// `status` says how it went.
pub fn start(cache: PathBuf, volume: f32) -> bool {
    stop();
    let shared = Arc::new(Shared {
        published: Mutex::new(Publications::default()),
        out: Mutex::new(VecDeque::new()),
        volume: AtomicU32::new(clean_volume(volume).to_bits()),
        stop: AtomicBool::new(false),
        state: AtomicU32::new(STATE_LOADING),
        voices: AtomicU32::new(0),
        underruns: AtomicU32::new(0),
        frames: AtomicU64::new(0),
        sounding: AtomicBool::new(false),
        message: Mutex::new(format!("loading {}", cache.display())),
        debug: Mutex::new(String::new()),
    });
    let for_thread = Arc::clone(&shared);
    let thread = std::thread::Builder::new()
        .name("skate3-audio".into())
        .stack_size(8 * 1024 * 1024)
        .spawn(move || {
            let s = for_thread;
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run(&s, cache)));
            let message = match result {
                Ok(Ok(())) => return,
                Ok(Err(e)) => e,
                Err(p) => format!(
                    "the audio thread crashed: {}",
                    p.downcast_ref::<String>()
                        .map(String::as_str)
                        .or_else(|| p.downcast_ref::<&str>().copied())
                        .unwrap_or("unknown")
                ),
            };
            s.state.store(STATE_ERROR, Ordering::Relaxed);
            set_message(&s, message);
        });
    let Ok(thread) = thread else { return false };
    if let Ok(mut g) = slot().lock() {
        *g = Some(Running {
            shared,
            thread: Some(thread),
        });
    }
    true
}

/// Stops the engine and waits for its thread: none may still run this
/// library's code once the game unloads it.
pub fn stop() {
    let old = slot().lock().ok().and_then(|mut g| g.take());
    if let Some(mut old) = old {
        old.shared.stop.store(true, Ordering::Relaxed);
        if let Some(t) = old.thread.take() {
            let _ = t.join();
        }
    }
}

fn clean_volume(v: f32) -> f32 {
    if v.is_finite() {
        v.clamp(0.0, 4.0)
    } else {
        1.0
    }
}

pub fn set_volume(v: f32) {
    if let Some(s) = current() {
        s.volume.store(clean_volume(v).to_bits(), Ordering::Relaxed);
    }
}

/// One line for the console: the state, voices and underruns.
pub fn status() -> String {
    let Some(s) = current() else {
        return "off".into();
    };
    let state = match s.state.load(Ordering::Relaxed) {
        STATE_LOADING => "loading",
        STATE_READY => "ready",
        STATE_ERROR => "error",
        _ => "off",
    };
    let message = s.message.lock().map(|m| m.clone()).unwrap_or_default();
    format!(
        "{state}: {message} ({} voices, {} underruns, {} frames)",
        s.voices.load(Ordering::Relaxed),
        s.underruns.load(Ordering::Relaxed),
        s.frames.load(Ordering::Relaxed)
    )
}

/// What is sounding, per class; empty when the engine isn't running.
pub fn debug_text() -> String {
    current()
        .and_then(|s| s.debug.lock().ok().map(|d| d.clone()))
        .unwrap_or_default()
}

/// The three emitters mixed to one centred channel, kept from clipping.
fn mix(block: &[[f32; BLOCK]; EMITTERS], i: usize, volume: f32) -> f32 {
    let sum = (block[0][i] + block[1][i] + block[2][i]) * volume;
    // Linear below 0.9, then bends toward 1.0.
    let a = sum.abs();
    if a <= 0.9 {
        sum
    } else {
        sum.signum() * (0.9 + 0.1 * ((a - 0.9) / 0.1).tanh())
    }
}

fn run(s: &Arc<Shared>, cache: PathBuf) -> Result<(), String> {
    let started = std::time::Instant::now();
    let mut engine = live::Engine::open(&cache, None)?;
    engine.driver.ensure_live_ready()?;
    // The output opens after the engine loads, so a device that fails
    // says so with the engine's cache already known good.
    let _stream = open_output(Arc::clone(s))?;
    set_message(
        s,
        format!(
            "engine ready in {} ms: {}",
            started.elapsed().as_millis(),
            engine.summary()
        ),
    );
    s.state.store(STATE_READY, Ordering::Relaxed);
    let mut produced: u64 = 0;
    let mut next_game_frame = 0u64;
    let mut published = Published::default();
    let mut block = [[0.0f32; BLOCK]; EMITTERS];
    let mut problems_logged = 0usize;
    let mut debug_frames = 0u64;
    while !s.stop.load(Ordering::Relaxed) {
        let queued = s
            .out
            .lock()
            .map_err(|_| "the output ring was poisoned")?
            .len()
            / 2;
        if queued >= LEAD_FRAMES {
            std::thread::sleep(Duration::from_millis(2));
            continue;
        }
        if produced >= next_game_frame || !published.active {
            // Frames beyond MAX_BACKLOG (a hitch, then the simulation
            // catching up) are applied at once instead of one per 1/60 s of
            // audio, which would delay every later sound by the backlog.
            let batch: Vec<Published> = {
                let mut queue = s
                    .published
                    .lock()
                    .map_err(|_| "audio publications were poisoned")?;
                if queue.overflow {
                    return Err("the audio's gameplay queue overflowed".into());
                }
                let n = queue
                    .pending
                    .len()
                    .saturating_sub(MAX_BACKLOG)
                    .max(1)
                    .min(queue.pending.len());
                queue.pending.drain(..n).collect()
            };
            if let Some(next) = batch.last().cloned() {
                for p in &batch {
                    engine.set_active(p.active);
                    if p.active {
                        engine.set_frame(&p.frame);
                    }
                }
                published = next;
                next_game_frame = next_game_frame.max(produced.saturating_sub(BLOCK as u64))
                    + SAMPLE_RATE as u64 / 60;
            } else {
                next_game_frame = produced;
            }
        }
        if !published.active && engine.idle() {
            next_game_frame = produced;
            s.voices.store(0, Ordering::Relaxed);
            s.sounding.store(false, Ordering::Relaxed);
            std::thread::sleep(Duration::from_millis(10));
            continue;
        }
        let info = engine.render(&mut block);
        let volume = f32::from_bits(s.volume.load(Ordering::Relaxed));
        {
            let mut out = s.out.lock().map_err(|_| "the output ring was poisoned")?;
            for i in 0..BLOCK {
                let m = mix(&block, i, volume);
                out.push_back(m);
                out.push_back(m);
            }
        }
        produced += BLOCK as u64;
        s.frames.store(produced, Ordering::Relaxed);
        let voices: u32 = info.iter().map(|i| i.voices).sum();
        s.voices.store(voices, Ordering::Relaxed);
        s.sounding.store(voices > 0, Ordering::Relaxed);
        debug_frames += BLOCK as u64;
        if debug_frames >= u64::from(SAMPLE_RATE) / 4 {
            let mut meters = engine.take_meters(debug_frames);
            meters.sort_by(|a, b| b.1.total_cmp(&a.1));
            let mut text = String::new();
            for (class, rms, share, voices) in meters {
                text.push_str(&format!(
                    "{class}: {rms:.0} dBFS, {:.0}% of the time, {voices} voice{}\n",
                    share * 100.0,
                    if voices == 1 { "" } else { "s" }
                ));
            }
            if let Ok(mut d) = s.debug.lock() {
                *d = text;
            }
            debug_frames = 0;
        }
        if problems_logged < 50 && engine.problem_count() > problems_logged {
            let problems = engine.problems();
            if let Some(line) = problems.get(problems_logged) {
                set_message(s, format!("{line}"));
            }
            problems_logged = problems.len().min(50);
        }
    }
    Ok(())
}

/// Opens the default output device and plays the ring on it. The stream must
/// stay alive on the thread that made it.
fn open_output(s: Arc<Shared>) -> Result<cpal::Stream, String> {
    let host = cpal::default_host();
    let device = host
        .default_output_device()
        .ok_or("there is no audio output device")?;
    let default = device
        .default_output_config()
        .map_err(|e| format!("the audio device has no usable format: {e}"))?;
    let config = StreamConfig {
        channels: default.channels(),
        sample_rate: default.sample_rate(),
        buffer_size: cpal::BufferSize::Default,
    };
    let stream = match default.sample_format() {
        SampleFormat::F32 => build::<f32>(&device, config, s),
        SampleFormat::I16 => build::<i16>(&device, config, s),
        SampleFormat::I32 => build::<i32>(&device, config, s),
        SampleFormat::U16 => build::<u16>(&device, config, s),
        other => Err(format!(
            "the audio device wants {other:?}, which isn't supported"
        )),
    }?;
    stream
        .play()
        .map_err(|e| format!("the audio device wouldn't start: {e}"))?;
    Ok(stream)
}

/// Pulls from the ring into the device's format, resampling linearly when the
/// device doesn't run at 48 kHz.
fn build<T>(
    device: &cpal::Device,
    config: StreamConfig,
    s: Arc<Shared>,
) -> Result<cpal::Stream, String>
where
    T: SizedSample + FromSample<f32>,
{
    let channels = usize::from(config.channels.max(1));
    let step = f64::from(SAMPLE_RATE) / f64::from(config.sample_rate.max(1));
    let mut phase = 0.0f64;
    let mut last = [0.0f32; 2];
    let mut next = [0.0f32; 2];
    let callback = move |data: &mut [T], _: &cpal::OutputCallbackInfo| {
        let Ok(mut ring) = s.out.try_lock() else {
            // The audio thread is writing; a short gap beats waiting.
            data.fill(T::from_sample(0.0));
            return;
        };
        let mut starved = false;
        for frame in data.chunks_mut(channels) {
            // Advance the source to the output frame's position.
            while phase >= 1.0 {
                last = next;
                match (ring.pop_front(), ring.pop_front()) {
                    (Some(l), Some(r)) => next = [l, r],
                    _ => {
                        starved = true;
                        next = [0.0; 2];
                    }
                }
                phase -= 1.0;
            }
            let t = phase as f32;
            let l = last[0] + (next[0] - last[0]) * t;
            let r = last[1] + (next[1] - last[1]) * t;
            phase += step;
            match channels {
                1 => frame[0] = T::from_sample((l + r) * 0.5),
                _ => {
                    frame[0] = T::from_sample(l);
                    frame[1] = T::from_sample(r);
                    for extra in &mut frame[2..] {
                        *extra = T::from_sample(0.0);
                    }
                }
            }
        }
        if starved && s.sounding.load(Ordering::Relaxed) {
            s.underruns.fetch_add(1, Ordering::Relaxed);
        }
    };
    let failed = |e: cpal::Error| {
        let _ = e;
    };
    device
        .build_output_stream(config, callback, failed, None)
        .map_err(|e| format!("couldn't open the audio device: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_event_and_deactivation_survive_a_delayed_consumer() {
        let mut q = Publications::default();
        for tick in 7..10 {
            q.push(Published {
                active: tick != 9,
                ..Default::default()
            });
        }
        let events: Vec<_> = q.pending.drain(..).map(|p| p.active).collect();
        assert_eq!(events, [true, true, false]);
        assert!(!q.overflow);
    }

    #[test]
    fn stalled_consumer_fails_explicitly_at_the_bound() {
        let mut q = Publications::default();
        for _ in 0..=MAX_PENDING {
            q.push(Published {
                active: true,
                ..Default::default()
            });
        }
        assert!(q.overflow);
        assert_eq!(q.pending.len(), MAX_PENDING);
    }

    #[test]
    fn the_mix_is_linear_when_quiet_and_never_clips() {
        let mut block = [[0.0f32; BLOCK]; EMITTERS];
        block[0][0] = 0.25;
        block[1][0] = 0.25;
        assert!((mix(&block, 0, 1.0) - 0.5).abs() < 1e-6);
        block[0][1] = 3.0;
        block[2][1] = 3.0;
        assert!(mix(&block, 1, 1.0) <= 1.0);
        block[0][2] = -3.0;
        assert!(mix(&block, 2, 1.0) >= -1.0);
        assert!(mix(&block, 0, 0.0).abs() < 1e-9);
    }

    #[test]
    fn volume_is_kept_sane() {
        assert_eq!(clean_volume(f32::NAN), 1.0);
        assert_eq!(clean_volume(-1.0), 0.0);
        assert_eq!(clean_volume(100.0), 4.0);
    }

    #[test]
    fn not_started_means_off() {
        assert_eq!(status(), "off");
        assert!(!ready());
        assert!(debug_text().is_empty());
    }
}
