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
use skate_aems::live::frame::Field;
use skate_aems::live::{self, EMITTERS};

use crate::audio_map as map;
use crate::spatial::{self, Mover, Placement, Reverb, Space};

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

/// Skate 3 material (a row of its AudioSurfaceMap) under the board, as Lua
/// found it from Source's surface; `NO_GROUND` until it says.
static GROUND: AtomicU32 = AtomicU32::new(NO_GROUND);
const NO_GROUND: u32 = u32::MAX;
/// The material of what is being ground, when Lua found one apart from the
/// ground under it (a metal rail on concrete).
static GRIND: AtomicU32 = AtomicU32::new(NO_GROUND);

/// Sets the material of the rail or ledge under the board while grinding.
pub fn set_grind(row: Option<u32>) {
    GRIND.store(row.unwrap_or(NO_GROUND), Ordering::Relaxed);
}

/// Sets the material the skater's wheels, board and feet stand on. Retail
/// reads it per triangle from the collision map; Source maps carry no such
/// tag, so Lua names it from the surface property under the board.
pub fn set_ground(row: Option<u32>) {
    GROUND.store(row.unwrap_or(NO_GROUND), Ordering::Relaxed);
}

/// Puts the ground material into the skater-state fields that name a surface:
/// each wheel (620), the board's other parts (652), the feet (728, 732) and the
/// grind (692). Zero-based table indexes, as the handlers read them.
fn apply_ground(frame: &mut live::Frame) {
    let row = GROUND.load(Ordering::Relaxed);
    if row == NO_GROUND {
        return;
    }
    let wheels = (0..4).map(|i| 620 + 4 * i);
    let parts = (0..3).map(|i| 652 + 4 * i);
    for offset in wheels.chain(parts).chain([728, 732]) {
        frame.fields.push((offset, Field::U32(row)));
    }
    let grind = GRIND.load(Ordering::Relaxed);
    frame.fields.push((
        692,
        Field::U32(if grind == NO_GROUND { row } else { grind }),
    ));
}

/// Front-end sound events Lua posted (name hash, the suspends that must have
/// happened first, when posted). An event waits out every ride stop asked for
/// before it, so the session marker's sound, posted as the ride restarts at
/// the marker, plays on the new ride and isn't cut by the old one's end.
static UI_EVENTS: Mutex<Vec<(u64, u32, std::time::Instant)>> = Mutex::new(Vec::new());
/// Ride stops Lua asked for, and ones the simulation thread has carried out.
static SUSPENDS_ASKED: AtomicU32 = AtomicU32::new(0);
static SUSPENDS_DONE: AtomicU32 = AtomicU32::new(0);
/// An event no ride picked up by then is dropped.
const UI_EVENT_LIFE: Duration = Duration::from_secs(2);

/// Lua asked the ride to stop (on Lua's thread, before the job is sent).
pub fn suspend_asked() {
    SUSPENDS_ASKED.fetch_add(1, Ordering::SeqCst);
}

/// The simulation thread stopped the ride Lua asked it to.
pub fn suspend_done() {
    SUSPENDS_DONE.fetch_add(1, Ordering::SeqCst);
}

/// Plays a front-end sound event (retail's GlobalFEPlaySound) by its name, on
/// the next simulation tick of a ride. False when the engine isn't playing,
/// so Lua plays its own.
pub fn post_event(name: &str) -> bool {
    if !ready() || name.is_empty() {
        return false;
    }
    let key = skate_aems::glue::seams::name_hash(name.as_bytes());
    let after = SUSPENDS_ASKED.load(Ordering::SeqCst);
    if let Ok(mut q) = UI_EVENTS.lock() {
        q.retain(|e| e.2.elapsed() < UI_EVENT_LIFE);
        if q.len() < 16 {
            q.push((key, after, std::time::Instant::now()));
        }
    }
    true
}

/// The events whose ride this is.
fn take_events(frame: &mut live::Frame) {
    let done = SUSPENDS_DONE.load(Ordering::SeqCst);
    if let Ok(mut q) = UI_EVENTS.lock() {
        if q.is_empty() {
            return;
        }
        q.retain(|e| {
            if e.2.elapsed() >= UI_EVENT_LIFE {
                false
            } else if done.wrapping_sub(e.1) as i32 >= 0 {
                frame.ui_events.push(e.0);
                false
            } else {
                true
            }
        });
    }
}

/// Called after every simulation tick: reads the session's audio state
/// (read-only) and queues it for the audio thread.
pub fn on_tick(session: &skate_bridge::bridge::Session, state: &mut map::State) {
    let Some(s) = current().filter(|s| s.state.load(Ordering::Relaxed) != STATE_ERROR) else {
        return;
    };
    let mut frame = state.frame(session);
    apply_ground(&mut frame);
    take_events(&mut frame);
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

/// Linear below 0.9, then bends toward 1.0, so nothing clips.
fn limit(sum: f32) -> f32 {
    let a = sum.abs();
    if a <= 0.9 {
        sum
    } else {
        sum.signum() * (0.9 + 0.1 * ((a - 0.9) / 0.1).tanh())
    }
}

/// Where the listener and the sounds are, from Lua; nothing set means every
/// sound is centred at full level, as before 3D.
static SPACE: Mutex<Option<Space>> = Mutex::new(None);
/// The room's reverb: wet level and seconds to decay.
static ROOM: Mutex<(f32, f32)> = Mutex::new((0.0, 1.0));

/// AudioSpace: `None` turns the placement off.
pub fn set_space(space: Option<Space>) {
    if let Ok(mut s) = SPACE.lock() {
        *s = space;
    }
}

pub fn set_room(wet: f32, decay: f32) {
    if let Ok(mut r) = ROOM.lock() {
        *r = (
            if wet.is_finite() { wet.clamp(0.0, 1.0) } else { 0.0 },
            if decay.is_finite() { decay.clamp(0.1, 8.0) } else { 1.0 },
        );
    }
}

/// What turns the three emitters into stereo: placement of the board and
/// body, the speed sounds on the listener, then the room.
struct Mixer {
    movers: [Mover; EMITTERS],
    reverb: Reverb,
}

impl Mixer {
    fn new() -> Self {
        Mixer {
            movers: [Mover::default(); EMITTERS],
            reverb: Reverb::new(SAMPLE_RATE),
        }
    }

    /// Forgets tails (the engine went quiet).
    fn clear(&mut self) {
        self.movers = [Mover::default(); EMITTERS];
        self.reverb.clear();
    }

    fn mix(
        &mut self,
        block: &[[f32; BLOCK]; EMITTERS],
        volume: f32,
        space: Option<Space>,
        wet: f32,
        decay: f32,
    ) -> [[f32; 2]; BLOCK] {
        let mut out = [[0.0f32; 2]; BLOCK];
        for (e, input) in block.iter().enumerate() {
            let target = match (&space, e) {
                (Some(sp), 0 | 1) => spatial::place(sp, e, SAMPLE_RATE as f32),
                _ => Placement::CENTRED,
            };
            let mut scaled = [0.0f32; BLOCK];
            for (o, x) in scaled.iter_mut().zip(input) {
                *o = x * volume;
            }
            self.movers[e].mix(&scaled, target, &mut out);
        }
        if space.is_some() {
            self.reverb.set_decay(decay);
            self.reverb.add_to(&mut out, wet);
        }
        for frame in out.iter_mut() {
            frame[0] = limit(frame[0]);
            frame[1] = limit(frame[1]);
        }
        out
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
    let mut mixer = Mixer::new();
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
            mixer.clear();
            std::thread::sleep(Duration::from_millis(10));
            continue;
        }
        let info = engine.render(&mut block);
        let volume = f32::from_bits(s.volume.load(Ordering::Relaxed));
        let space = SPACE.lock().ok().and_then(|g| *g);
        let (wet, decay) = ROOM.lock().map(|g| *g).unwrap_or((0.0, 1.0));
        let stereo = mixer.mix(&block, volume, space, wet, decay);
        {
            let mut out = s.out.lock().map_err(|_| "the output ring was poisoned")?;
            for frame in &stereo {
                out.push_back(frame[0]);
                out.push_back(frame[1]);
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
        let mut mixer = Mixer::new();
        let out = mixer.mix(&block, 1.0, None, 0.0, 1.0);
        assert!((out[0][0] - 0.5).abs() < 1e-6 && (out[0][1] - 0.5).abs() < 1e-6);
        block[0][1] = 3.0;
        block[2][1] = 3.0;
        block[0][2] = -3.0;
        block[2][2] = -3.0;
        let out = mixer.mix(&block, 1.0, None, 0.0, 1.0);
        assert!(out[1][0] <= 1.0 && out[2][0] >= -1.0);
        let silent = mixer.mix(&block, 0.0, None, 0.0, 1.0);
        assert!(silent.iter().all(|f| f[0].abs() < 1e-9 && f[1].abs() < 1e-9));
    }

    fn test_space(board: [f32; 3]) -> Space {
        Space {
            listener: [0.0; 3],
            right: [1.0, 0.0, 0.0],
            emitters: [board, board],
        }
    }

    #[test]
    fn a_board_next_to_you_sounds_exactly_as_before() {
        let mut block = [[0.0f32; BLOCK]; EMITTERS];
        block[0].fill(0.1);
        block[2].fill(0.05);
        let plain = Mixer::new().mix(&block, 1.0, None, 0.0, 1.0);
        let near = Mixer::new().mix(&block, 1.0, Some(test_space([1.0, 0.0, 0.0])), 0.0, 1.0);
        for (a, b) in plain.iter().zip(&near) {
            assert!((a[0] - b[0]).abs() < 1e-5 && (a[1] - b[1]).abs() < 1e-5);
        }
    }

    #[test]
    fn a_board_far_off_to_the_right_is_quieter_and_on_the_right() {
        let mut block = [[0.0f32; BLOCK]; EMITTERS];
        block[0].fill(0.2);
        let mut mixer = Mixer::new();
        let space = Some(test_space([40.0, 0.0, 0.0]));
        let mut last = [[0.0; 2]; BLOCK];
        for _ in 0..20 {
            last = mixer.mix(&block, 1.0, space, 0.0, 1.0);
        }
        let end = last[BLOCK - 1];
        assert!(end[1] > end[0], "right ear louder: {end:?}");
        assert!(end[1] < 0.2 * 0.5, "far is quieter: {end:?}");
    }

    #[test]
    fn the_room_adds_a_tail_after_the_sound_stops() {
        let mut block = [[0.0f32; BLOCK]; EMITTERS];
        block[0][0] = 0.8;
        let space = Some(test_space([1.0, 0.0, 0.0]));
        let mut mixer = Mixer::new();
        let first = mixer.mix(&block, 1.0, space, 0.5, 2.0);
        block[0][0] = 0.0;
        let mut tail = 0.0f32;
        for _ in 0..40 {
            let out = mixer.mix(&block, 1.0, space, 0.5, 2.0);
            tail = tail.max(out.iter().map(|f| f[0].abs()).fold(0.0, f32::max));
        }
        assert!(first[0][0].is_finite());
        assert!(tail > 1e-5, "reverb tail missing: {tail}");
        mixer.clear();
        let after = mixer.mix(&block, 1.0, space, 0.0, 2.0);
        assert!(after.iter().all(|f| f[0].abs() < 1e-9));
    }

    #[test]
    fn an_event_posted_with_a_restart_waits_for_the_new_ride() {
        // The marker: Lua stops the ride, starts it at the marker, posts the
        // sound. The old ride's last tick must not take it.
        suspend_asked();
        let key = skate_aems::glue::seams::name_hash(b"cellphone_goto_marker");
        assert_eq!(key, 0x7f13_5f9f_d28f_7f21);
        let after = SUSPENDS_ASKED.load(Ordering::SeqCst);
        UI_EVENTS.lock().unwrap().push((key, after, std::time::Instant::now()));
        let mut old = live::Frame::default();
        take_events(&mut old);
        assert!(old.ui_events.is_empty());
        suspend_done();
        let mut new = live::Frame::default();
        take_events(&mut new);
        assert_eq!(new.ui_events, vec![key]);
        let mut next = live::Frame::default();
        take_events(&mut next);
        assert!(next.ui_events.is_empty());
    }

    #[test]
    fn the_ground_material_overrides_every_surface_field() {
        let mut frame = live::Frame::default();
        frame.fields.push((620, Field::U32(143)));
        set_ground(Some(9));
        set_grind(None);
        apply_ground(&mut frame);
        set_grind(Some(8));
        let mut rail = live::Frame::default();
        apply_ground(&mut rail);
        assert_eq!(live::frame::SkaterImage::from_frame(&rail).r32(692), 8);
        assert_eq!(live::frame::SkaterImage::from_frame(&rail).r32(620), 9);
        set_grind(None);
        set_ground(None);
        let image = live::frame::SkaterImage::from_frame(&frame);
        for offset in [620, 624, 628, 632, 652, 656, 660, 692, 728, 732] {
            assert_eq!(image.r32(offset), 9, "offset {offset}");
        }
        let mut untouched = live::Frame::default();
        apply_ground(&mut untouched);
        assert!(untouched.fields.is_empty());
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
