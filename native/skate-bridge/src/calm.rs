//! Calm limbs: the arms drawn from the animation instead of the body.
//!
//! Skate 3 drives the skater's body toward its animation with springs, and
//! the pose it hands out is the body's. On a fast animation (an on-foot
//! jump's arm swing, a gesture, a flail) the springs overshoot: the hands
//! fly well past where the animation has them and snap back, which on a
//! playermodel reads as rubber arms. Here each arm takes the animation's
//! own pose, carried on the body's chest, so the swing is as fast as it
//! was animated and no faster. A hand at the board keeps the body's pose
//! (it is holding the deck there), and so does everything in a bail.

use glam::Mat4;

/// The bone each arm hangs from, and the arm from the shoulder down.
const ARMS: [(&str, [&str; 4]); 2] = [
    ("SPINE3", ["RIGHTSHOULDER", "RIGHTARM", "RIGHTFOREARM", "RIGHTHAND"]),
    ("SPINE3", ["LEFTSHOULDER", "LEFTARM", "LEFTFOREARM", "LEFTHAND"]),
];
const BOARD: &str = "SKATEBOARD_ROOT";
/// Metres from the board's middle: a hand closer than NEAR is the body's,
/// one further than FAR is the animation's, eased in between.
const NEAR: f32 = 0.55;
const FAR: f32 = 0.8;
/// How much of the way in or out of a bail the arms move each step.
const GATE_STEP: f32 = 0.2;

pub struct Calm {
    /// 1 while the arms are the animation's, 0 in a bail, eased between.
    gate: f32,
}

impl Default for Calm {
    fn default() -> Self {
        Self { gate: 1. }
    }
}

impl Calm {
    /// `bones`: the body's pose by name. `animation`: this step's animation
    /// pose, in the same order and space. `metre`: one metre in that space.
    pub fn apply(&mut self, bones: &mut [(String, Mat4)], animation: &[Mat4], state: &str, metre: f32) {
        let bailing = state.starts_with("Wipeout");
        self.gate = (self.gate + if bailing { -GATE_STEP } else { GATE_STEP }).clamp(0., 1.);
        if self.gate <= 0. {
            return;
        }
        let board = find(bones, BOARD).map(|i| bones[i].1.w_axis.truncate());
        for (anchor, chain) in ARMS {
            let Some(anchor) = find(bones, anchor) else { continue };
            let chain: Vec<usize> = chain.iter().filter_map(|name| find(bones, name)).collect();
            if chain.len() != 4 || anchor >= animation.len() || chain.iter().any(|&i| i >= animation.len()) {
                continue;
            }
            // The animation's arm, carried on the body's chest.
            let carry = bones[anchor].1 * animation[anchor].inverse();
            let hand = bones[chain[3]].1.w_axis.truncate();
            let free = board.map_or(1., |b| smooth((hand.distance(b) / metre - NEAR) / (FAR - NEAR)));
            let weight = self.gate * free;
            if weight <= 0. {
                continue;
            }
            for i in chain {
                let target = carry * animation[i];
                if target.is_finite() {
                    bones[i].1 = mix(bones[i].1, target, weight);
                }
            }
        }
    }
}

fn find(bones: &[(String, Mat4)], name: &str) -> Option<usize> {
    bones.iter().position(|(n, _)| n == name)
}

fn smooth(t: f32) -> f32 {
    let t = t.clamp(0., 1.);
    t * t * (3. - 2. * t)
}

/// `t` of the way from one bone matrix to another.
fn mix(a: Mat4, b: Mat4, t: f32) -> Mat4 {
    if t >= 1. {
        return b;
    }
    let (scale, ra, ta) = a.to_scale_rotation_translation();
    let (_, rb, tb) = b.to_scale_rotation_translation();
    let out = Mat4::from_scale_rotation_translation(scale, ra.slerp(rb, t), ta.lerp(tb, t));
    if out.is_finite() { out } else { a }
}

#[cfg(test)]
mod tests {
    use super::*;
    use glam::Vec3;

    fn pose(hand: Vec3) -> Vec<(String, Mat4)> {
        let at = |name: &str, p: Vec3| (name.to_string(), Mat4::from_translation(p));
        vec![
            at("SPINE3", Vec3::new(0., 1.3, 0.)),
            at("RIGHTSHOULDER", Vec3::new(-0.1, 1.4, 0.)),
            at("RIGHTARM", Vec3::new(-0.2, 1.4, 0.)),
            at("RIGHTFOREARM", Vec3::new(-0.2, 1.1, 0.)),
            at("RIGHTHAND", hand),
            at(BOARD, Vec3::ZERO),
        ]
    }

    #[test]
    fn a_free_hand_takes_the_animation_and_a_bail_keeps_the_body() {
        let animation: Vec<Mat4> = pose(Vec3::new(-0.2, 1.5, 0.)).into_iter().map(|(_, m)| m).collect();
        // The body's hand overshot to 1.9 m.
        let mut bones = pose(Vec3::new(-0.2, 1.9, 0.));
        let mut calm = Calm::default();
        calm.apply(&mut bones, &animation, "BipedAir", 1.);
        assert!((bones[4].1.w_axis.y - 1.5).abs() < 1e-5);
        // In a bail the arms ease back to the body's over a few steps.
        let mut last = 1.5;
        for _ in 0..6 {
            bones = pose(Vec3::new(-0.2, 1.9, 0.));
            calm.apply(&mut bones, &animation, "WipeoutRagdoll", 1.);
            assert!(bones[4].1.w_axis.y >= last - 1e-5);
            last = bones[4].1.w_axis.y;
        }
        assert!((last - 1.9).abs() < 1e-5);
    }

    #[test]
    fn a_hand_at_the_board_keeps_the_body() {
        let animation: Vec<Mat4> = pose(Vec3::new(-0.2, 0.5, 0.)).into_iter().map(|(_, m)| m).collect();
        let mut bones = pose(Vec3::new(-0.2, 0.3, 0.));
        Calm::default().apply(&mut bones, &animation, "PhysicsAir", 1.);
        assert!((bones[4].1.w_axis.y - 0.3).abs() < 1e-5);
    }

    #[test]
    fn the_arm_rides_the_bodys_chest() {
        let animation: Vec<Mat4> = pose(Vec3::new(-0.2, 1.5, 0.)).into_iter().map(|(_, m)| m).collect();
        let mut bones = pose(Vec3::new(-0.2, 1.9, 0.));
        // The body's chest is 0.1 m higher than the animation's.
        bones[0].1 = Mat4::from_translation(Vec3::new(0., 1.4, 0.));
        Calm::default().apply(&mut bones, &animation, "BipedAir", 1.);
        assert!((bones[4].1.w_axis.y - 1.6).abs() < 1e-5);
    }
}
