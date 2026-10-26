//! Where the sounds are, and the room they're in.
//!
//! The audio engine renders dry, centred streams (one per emitter: the board,
//! the body and the speed sounds that ride with the camera). Retail's own mixer
//! placed them in the world; here a board that rolls away has to get quieter,
//! duller and to one side, and a canyon or a tunnel has to ring. Lua says where
//! the listener and the emitters are and how enclosed the room looks
//! (`AudioSpace`, `AudioReverb`); this turns that into a gain per ear, a
//! low-pass and a reverb on the mix.
//!
//! Close sounds are left exactly as they were: up to `NEAR` metres an emitter
//! plays at full level in the middle, so the camera trailing a skater behind
//! it doesn't make the skater quieter.

use std::f32::consts::TAU;

/// Metres up to which an emitter plays at full level, centred.
pub const NEAR: f32 = 6.0;
/// Metres at which it has faded out.
pub const FAR: f32 = 90.0;
/// Metres within which a sound stays in the middle, and the span over which it
/// moves out to its side.
const PAN_FROM: f32 = 2.0;
const PAN_SPAN: f32 = 6.0;
/// The most a sound is panned (1 is all the way to one ear).
const PAN_MAX: f32 = 0.9;
/// The low-pass's cut-off at `NEAR` and at `FAR` (Hz): the air takes the
/// highs off a distant sound.
const CUT_NEAR: f32 = 20_000.0;
const CUT_FAR: f32 = 2_500.0;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Space {
    pub listener: [f32; 3],
    /// Unit vector out of the listener's right ear.
    pub right: [f32; 3],
    /// The board and the body, in metres. The speed sounds ride on the
    /// listener and aren't placed.
    pub emitters: [[f32; 3]; 2],
}

/// What an emitter's distance and direction come to.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Placement {
    pub left: f32,
    pub right: f32,
    /// One-pole low-pass coefficient, 1 for none.
    pub smooth: f32,
}

impl Placement {
    pub const CENTRED: Placement = Placement { left: 1.0, right: 1.0, smooth: 1.0 };
}

fn smoothstep(edge0: f32, edge1: f32, x: f32) -> f32 {
    let t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// Level for a distance in metres: full inside `NEAR`, then inversely with
/// distance, fading to nothing by `FAR`.
pub fn distance_gain(d: f32) -> f32 {
    if d <= NEAR {
        return 1.0;
    }
    (NEAR / d) * (1.0 - smoothstep(FAR * 0.6, FAR, d))
}

/// The one-pole coefficient for a cut-off at `sample_rate`.
fn one_pole(cut: f32, sample_rate: f32) -> f32 {
    1.0 - (-TAU * cut / sample_rate).exp()
}

pub fn place(space: &Space, emitter: usize, sample_rate: f32) -> Placement {
    let Some(at) = space.emitters.get(emitter) else {
        return Placement::CENTRED;
    };
    let to = [
        at[0] - space.listener[0],
        at[1] - space.listener[1],
        at[2] - space.listener[2],
    ];
    let d = (to[0] * to[0] + to[1] * to[1] + to[2] * to[2]).sqrt();
    if !d.is_finite() {
        return Placement::CENTRED;
    }
    let gain = distance_gain(d);
    // How far to the right of the listener it is, from -1 to 1.
    let side = if d > 1e-3 {
        (to[0] * space.right[0] + to[1] * space.right[1] + to[2] * space.right[2]) / d
    } else {
        0.0
    };
    let strength = ((d - PAN_FROM) / PAN_SPAN).clamp(0.0, 1.0);
    let pan = (side * strength * PAN_MAX).clamp(-PAN_MAX, PAN_MAX);
    // Equal level in the middle (as before), the far ear giving way.
    let left = gain * (1.0 - pan).min(1.0);
    let right = gain * (1.0 + pan).min(1.0);
    let t = ((d - NEAR) / (FAR - NEAR)).clamp(0.0, 1.0);
    let smooth = if t <= 0.0 {
        1.0
    } else {
        one_pole(CUT_NEAR * (CUT_FAR / CUT_NEAR).powf(t), sample_rate)
    };
    Placement { left, right, smooth }
}

/// A placement that eases toward its target over each block, so moving
/// sounds don't click.
#[derive(Clone, Copy, Debug)]
pub struct Mover {
    now: Placement,
    low: f32,
}

impl Default for Mover {
    fn default() -> Self {
        Mover { now: Placement::CENTRED, low: 0.0 }
    }
}

impl Mover {
    /// Mixes one block of mono `input` into `out` (left, right) at the
    /// placement moving toward `target`.
    pub fn mix(&mut self, input: &[f32], target: Placement, out: &mut [[f32; 2]]) {
        let n = input.len().max(1) as f32;
        let step = |from: f32, to: f32| (to - from) / n;
        let (dl, dr, ds) = (
            step(self.now.left, target.left),
            step(self.now.right, target.right),
            step(self.now.smooth, target.smooth),
        );
        for (x, o) in input.iter().zip(out.iter_mut()) {
            self.now.left += dl;
            self.now.right += dr;
            self.now.smooth += ds;
            let y = if self.now.smooth >= 0.999 {
                self.low = *x;
                *x
            } else {
                self.low += self.now.smooth * (x - self.low);
                self.low
            };
            o[0] += y * self.now.left;
            o[1] += y * self.now.right;
        }
        self.now = Placement {
            left: target.left,
            right: target.right,
            smooth: target.smooth,
        };
    }
}

// Freeverb's delays at 44.1 kHz, scaled to the sample rate; the right
// channel's a little longer.
const COMBS: [usize; 8] = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617];
const ALLPASSES: [usize; 4] = [556, 441, 341, 225];
const SPREAD: usize = 23;
/// How much of the comb's output the damping filter keeps back.
const DAMP: f32 = 0.35;

struct Comb {
    buffer: Vec<f32>,
    at: usize,
    store: f32,
    feedback: f32,
}

impl Comb {
    fn new(len: usize) -> Self {
        Comb { buffer: vec![0.0; len.max(1)], at: 0, store: 0.0, feedback: 0.0 }
    }

    fn run(&mut self, x: f32) -> f32 {
        let y = self.buffer[self.at];
        self.store = y * (1.0 - DAMP) + self.store * DAMP;
        self.buffer[self.at] = x + self.store * self.feedback;
        self.at = (self.at + 1) % self.buffer.len();
        y
    }
}

struct Allpass {
    buffer: Vec<f32>,
    at: usize,
}

impl Allpass {
    fn new(len: usize) -> Self {
        Allpass { buffer: vec![0.0; len.max(1)], at: 0 }
    }

    fn run(&mut self, x: f32) -> f32 {
        let held = self.buffer[self.at];
        self.buffer[self.at] = x + held * 0.5;
        self.at = (self.at + 1) % self.buffer.len();
        held - x
    }
}

/// A stereo room: eight damped combs and four all-passes a side, with the
/// feedback set so the tail falls 60 dB in the asked time.
pub struct Reverb {
    combs: [Vec<Comb>; 2],
    allpasses: [Vec<Allpass>; 2],
    sample_rate: f32,
    decay: f32,
    /// The wet level now and the one it eases to.
    wet: f32,
}

impl Reverb {
    pub fn new(sample_rate: u32) -> Self {
        let scale = sample_rate as f32 / 44_100.0;
        let size = |n: usize, extra: usize| (((n + extra) as f32) * scale).round() as usize;
        let side = |extra: usize| {
            (
                COMBS.iter().map(|n| Comb::new(size(*n, extra))).collect::<Vec<_>>(),
                ALLPASSES.iter().map(|n| Allpass::new(size(*n, extra))).collect::<Vec<_>>(),
            )
        };
        let (cl, al) = side(0);
        let (cr, ar) = side(SPREAD);
        let mut reverb = Reverb {
            combs: [cl, cr],
            allpasses: [al, ar],
            sample_rate: sample_rate as f32,
            decay: 0.0,
            wet: 0.0,
        };
        reverb.set_decay(1.0);
        reverb
    }

    /// Seconds for the tail to fall 60 dB.
    pub fn set_decay(&mut self, seconds: f32) {
        let seconds = seconds.clamp(0.1, 8.0);
        if (seconds - self.decay).abs() < 0.02 * self.decay.max(0.1) {
            return;
        }
        self.decay = seconds;
        for side in &mut self.combs {
            for comb in side {
                // A comb of n samples loses 60 dB over seconds * rate samples
                // when its feedback is 10^(-3 n / (seconds * rate)).
                let n = comb.buffer.len() as f32;
                comb.feedback = 10f32.powf(-3.0 * n / (seconds * self.sample_rate)).min(0.995);
            }
        }
    }

    pub fn clear(&mut self) {
        for side in &mut self.combs {
            for comb in side {
                comb.buffer.fill(0.0);
                comb.store = 0.0;
            }
        }
        for side in &mut self.allpasses {
            for all in side {
                all.buffer.fill(0.0);
            }
        }
        self.wet = 0.0;
    }

    /// Adds the room's reply to `block` (left, right). `target_wet` is how
    /// much of it to mix in, eased toward over the block.
    pub fn add_to(&mut self, block: &mut [[f32; 2]], target_wet: f32) {
        let n = block.len().max(1) as f32;
        let step = (target_wet - self.wet) / n;
        for frame in block.iter_mut() {
            self.wet += step;
            let input = (frame[0] + frame[1]) * 0.5 * 0.05;
            for (channel, out) in frame.iter_mut().enumerate() {
                let mut sum = 0.0;
                for comb in &mut self.combs[channel] {
                    sum += comb.run(input);
                }
                for all in &mut self.allpasses[channel] {
                    sum = all.run(sum);
                }
                *out += sum * self.wet;
            }
        }
        self.wet = target_wet;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RATE: f32 = 48_000.0;

    fn space(board: [f32; 3]) -> Space {
        Space {
            listener: [0.0, 0.0, 0.0],
            right: [1.0, 0.0, 0.0],
            emitters: [board, [0.0, 3.0, 0.0]],
        }
    }

    #[test]
    fn close_sounds_are_exactly_as_before() {
        let near = place(&space([0.0, 4.0, 0.0]), 0, RATE);
        assert_eq!(near, Placement::CENTRED);
        // Even a little to the side, inside the pan distance.
        let side = place(&space([1.5, 0.0, 0.0]), 0, RATE);
        assert_eq!((side.left, side.right, side.smooth), (1.0, 1.0, 1.0));
    }

    #[test]
    fn a_far_board_is_quieter_duller_and_gone_at_the_end() {
        let mut last = 1.1;
        for d in [8.0, 15.0, 30.0, 60.0, 85.0] {
            let p = place(&space([0.0, d, 0.0]), 0, RATE);
            assert!(p.left < last, "{d} m should be quieter than the one before");
            assert!(p.smooth < 1.0);
            last = p.left;
        }
        assert!(place(&space([0.0, FAR + 1.0, 0.0]), 0, RATE).left < 1e-6);
        // 12 m out is 6 dB down: the reference distance doubled.
        let p = place(&space([0.0, 12.0, 0.0]), 0, RATE);
        assert!((p.left - 0.5).abs() < 0.01, "{}", p.left);
    }

    #[test]
    fn a_sound_to_the_right_is_louder_in_the_right_ear() {
        let p = place(&space([20.0, 0.0, 0.0]), 0, RATE);
        assert!(p.right > p.left * 1.5, "{p:?}");
        let q = place(&space([-20.0, 0.0, 0.0]), 0, RATE);
        assert!(q.left > q.right * 1.5, "{q:?}");
        // Straight ahead stays in the middle.
        let ahead = place(&space([0.0, 20.0, 0.0]), 0, RATE);
        assert!((ahead.left - ahead.right).abs() < 1e-6);
    }

    #[test]
    fn the_speed_sounds_and_bad_input_stay_put() {
        assert_eq!(place(&space([0.0, 99.0, 0.0]), 2, RATE), Placement::CENTRED);
        let mut s = space([f32::NAN, 0.0, 0.0]);
        assert_eq!(place(&s, 0, RATE), Placement::CENTRED);
        s.emitters[0] = [0.0; 3];
        assert_eq!(place(&s, 0, RATE), Placement::CENTRED);
    }

    #[test]
    fn the_mover_passes_a_centred_sound_through_untouched() {
        let mut mover = Mover::default();
        let input: Vec<f32> = (0..64).map(|i| (i as f32 * 0.3).sin()).collect();
        let mut out = vec![[0.0f32; 2]; 64];
        mover.mix(&input, Placement::CENTRED, &mut out);
        for (x, o) in input.iter().zip(&out) {
            assert!((o[0] - x).abs() < 1e-6 && (o[1] - x).abs() < 1e-6);
        }
    }

    #[test]
    fn the_mover_eases_and_the_low_pass_takes_the_highs() {
        let mut mover = Mover::default();
        let far = Placement { left: 0.2, right: 0.2, smooth: one_pole(2_500.0, RATE) };
        // A signal at the Nyquist rate is all highs.
        let input: Vec<f32> = (0..256).map(|i| if i % 2 == 0 { 1.0 } else { -1.0 }).collect();
        let mut out = vec![[0.0f32; 2]; 256];
        mover.mix(&input, far, &mut out);
        assert!(out[0][0].abs() > 0.5, "starts at full level");
        let mut again = vec![[0.0f32; 2]; 256];
        mover.mix(&input, far, &mut again);
        let peak = again.iter().map(|o| o[0].abs()).fold(0.0, f32::max);
        assert!(peak < 0.1, "highs and level both gone: {peak}");
    }

    fn impulse_response(decay: f32, seconds: f32) -> Vec<f32> {
        let mut reverb = Reverb::new(48_000);
        reverb.set_decay(decay);
        let mut out = Vec::new();
        let total = (seconds * 48_000.0) as usize;
        let mut done = 0;
        while done < total {
            let mut block = vec![[0.0f32; 2]; 256];
            if done == 0 {
                block[0] = [1.0, 1.0];
            }
            reverb.add_to(&mut block, 1.0);
            // The block is the input plus the reply; drop the input.
            out.extend(block.iter().map(|f| f[0]));
            done += 256;
        }
        out[0] = 0.0;
        out
    }

    fn energy(slice: &[f32]) -> f32 {
        slice.iter().map(|x| x * x).sum::<f32>()
    }

    #[test]
    fn the_tail_rings_longer_in_a_bigger_room() {
        let short = impulse_response(0.4, 3.0);
        let long = impulse_response(3.0, 3.0);
        let late = 48_000..96_000; // 1 to 2 seconds in
        assert!(energy(&long[late.clone()]) > energy(&short[late]) * 100.0);
        // And it does die away.
        assert!(energy(&long[100_000..140_000]) < energy(&long[4_000..44_000]));
    }

    #[test]
    fn no_wet_is_no_reverb() {
        let mut reverb = Reverb::new(48_000);
        let mut block = vec![[0.5f32; 2]; 256];
        let dry = block.clone();
        reverb.add_to(&mut block, 0.0);
        assert_eq!(block, dry);
        // Clearing leaves it silent.
        reverb.add_to(&mut vec![[1.0f32; 2]; 256], 1.0);
        reverb.clear();
        let mut silent = vec![[0.0f32; 2]; 256];
        reverb.add_to(&mut silent, 1.0);
        assert!(silent.iter().all(|f| f[0] == 0.0 && f[1] == 0.0));
    }

    #[test]
    fn the_reverb_stays_stable() {
        let mut reverb = Reverb::new(48_000);
        reverb.set_decay(8.0);
        let mut peak = 0.0f32;
        for i in 0..400 {
            let mut block = vec![[0.0f32; 2]; 256];
            if i < 20 {
                block.iter_mut().for_each(|f| *f = [0.9, 0.9]);
            }
            reverb.add_to(&mut block, 1.0);
            peak = block.iter().map(|f| f[0].abs().max(f[1].abs())).fold(peak, f32::max);
        }
        assert!(peak.is_finite() && peak < 20.0, "{peak}");
    }
}
