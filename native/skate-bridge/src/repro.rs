//! Driving a session from frames of pad input, and saving everything a session
//! was fed so it can be replayed: the collision it was built on, then every
//! activation, frame and suspend in order. A fresh session fed the same
//! events steps the same way, so a ride that broke in the game breaks again
//! in skate-headless, where the engine can be traced.

use std::io::{self, Read, Write};

use crate::bridge::{Controls, InputFrame, Pose, Session};

/// The longest frame the simulation catches up on, as in the mashup.
pub const MAX_CATCH_UP: f32 = 0.15;

/// Steps a session the way the game does: sample the pad every frame,
/// publish actions on each simulation tick. One per session.
#[derive(Default)]
pub struct Driver {
    accumulated: f32,
    /// XInput's packet number, advanced every frame as the mashup does.
    packet: u32,
}

impl Driver {
    pub fn activate(
        &mut self,
        session: &mut Session,
        spawn: [f32; 3],
        heading: f32,
        aspect: f32,
    ) -> Result<Pose, String> {
        self.accumulated = 0.;
        session.set_aspect_ratio(aspect);
        session.activate(spawn, heading)
    }

    /// Feeds one frame; `on_tick` runs after every simulation tick. Returns
    /// whether the simulation advanced.
    pub fn step(
        &mut self,
        session: &mut Session,
        dt: f32,
        controls: Controls,
        aspect: f32,
        mut on_tick: impl FnMut(&Session),
    ) -> Result<bool, String> {
        let dt = dt.max(0.);
        session.set_aspect_ratio(aspect);
        self.packet = self.packet.wrapping_add(1);
        session.collect(
            InputFrame::from_pad(
                controls.buttons,
                controls.triggers,
                controls.left,
                controls.right,
                self.packet,
            ),
            dt,
        );
        self.accumulated = (self.accumulated + dt).min(MAX_CATCH_UP);
        let mut advanced = false;
        // The native camera can change the simulation period.
        while self.accumulated >= session.period() {
            self.accumulated -= session.period();
            session.advance()?;
            advanced = true;
            on_tick(session);
        }
        Ok(advanced)
    }

    pub fn suspend(&mut self, session: &mut Session) {
        self.accumulated = 0.;
        session.suspend_input();
    }
}

const MAGIC: &[u8; 4] = b"SK3R";
const VERSION: u32 = 3;
/// Rides saved before collision swaps and gestures were recorded.
const OLD_VERSION: u32 = 2;
/// Events kept per session: half an hour of frames at 60 a second.
pub const MAX_EVENTS: usize = 108_000;

/// A list rebuilt from an earlier one: keep `front` items from its start and
/// `back` from its end, with `middle` between them. Prop and door collision
/// mostly appends to the map's, so a swap stores only what changed.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Splice<T> {
    pub front: u32,
    pub back: u32,
    pub middle: Vec<T>,
}

impl<T: Clone + PartialEq> Splice<T> {
    pub fn between(old: &[T], new: &[T]) -> Self {
        let front = old.iter().zip(new).take_while(|(a, b)| a == b).count();
        let room = old.len().min(new.len()) - front;
        let back = old
            .iter()
            .rev()
            .zip(new.iter().rev())
            .take(room)
            .take_while(|(a, b)| a == b)
            .count();
        Self {
            front: front as u32,
            back: back as u32,
            middle: new[front..new.len() - back].to_vec(),
        }
    }

    pub fn apply(&self, old: &[T]) -> Result<Vec<T>, String> {
        let (front, back) = (self.front as usize, self.back as usize);
        if front + back > old.len() {
            return Err("a recorded collision swap doesn't fit the collision before it".into());
        }
        let mut out = old[..front].to_vec();
        out.extend_from_slice(&self.middle);
        out.extend_from_slice(&old[old.len() - back..]);
        Ok(out)
    }
}

#[derive(Clone)]
pub enum Event {
    /// Skate space, as `Session::activate` takes them.
    Activate {
        spawn: [f32; 3],
        heading: f32,
        aspect: f32,
    },
    Step {
        dt: f32,
        controls: Controls,
        aspect: f32,
    },
    Suspend,
    /// The skater's natural stance, set before an activation.
    Stance {
        goofy: bool,
    },
    /// Prop, door or surface-fix collision swapped in between two frames,
    /// as changes to the collision before it.
    Collision {
        triangles: Splice<[[f32; 3]; 3]>,
        rails: Splice<Vec<[f32; 3]>>,
    },
    /// The player's D-pad gesture picks (None = Skate 3's defaults).
    Gestures {
        picks: Option<[u32; 4]>,
    },
}

#[derive(Clone, Default)]
pub struct Recording {
    pub triangles: Vec<[[f32; 3]; 3]>,
    pub rails: Vec<Vec<[f32; 3]>>,
    pub events: Vec<Event>,
}

fn f32s(w: &mut impl Write, v: &[f32]) -> io::Result<()> {
    v.iter().try_for_each(|x| w.write_all(&x.to_le_bytes()))
}

fn u32s(w: &mut impl Write, v: u32) -> io::Result<()> {
    w.write_all(&v.to_le_bytes())
}

fn read<const N: usize>(r: &mut impl Read) -> io::Result<[u8; N]> {
    let mut b = [0u8; N];
    r.read_exact(&mut b)?;
    Ok(b)
}

fn read_u32(r: &mut impl Read) -> io::Result<u32> {
    Ok(u32::from_le_bytes(read(r)?))
}

fn read_f32(r: &mut impl Read) -> io::Result<f32> {
    Ok(f32::from_le_bytes(read(r)?))
}

fn read_point(r: &mut impl Read) -> io::Result<[f32; 3]> {
    Ok([read_f32(r)?, read_f32(r)?, read_f32(r)?])
}

fn read_rails(r: &mut impl Read, count: u32) -> io::Result<Vec<Vec<[f32; 3]>>> {
    (0..count)
        .map(|_| {
            let n = read_u32(r)?;
            (0..n).map(|_| read_point(r)).collect()
        })
        .collect()
}

impl Recording {
    pub fn new(triangles: Vec<[[f32; 3]; 3]>, rails: Vec<Vec<[f32; 3]>>) -> Self {
        Self {
            triangles,
            rails,
            events: Vec::new(),
        }
    }

    /// Adds an event; false once the recording is full and stopped.
    pub fn push(&mut self, event: Event) -> bool {
        if self.events.len() >= MAX_EVENTS {
            return false;
        }
        self.events.push(event);
        true
    }

    pub fn write(&self, w: &mut impl Write) -> io::Result<()> {
        w.write_all(MAGIC)?;
        u32s(w, VERSION)?;
        u32s(w, self.triangles.len() as u32)?;
        for t in &self.triangles {
            f32s(w, t.as_flattened())?;
        }
        u32s(w, self.rails.len() as u32)?;
        for r in &self.rails {
            u32s(w, r.len() as u32)?;
            f32s(w, r.as_flattened())?;
        }
        u32s(w, self.events.len() as u32)?;
        for e in &self.events {
            match e {
                Event::Activate {
                    spawn,
                    heading,
                    aspect,
                } => {
                    w.write_all(&[0])?;
                    f32s(w, spawn)?;
                    f32s(w, &[*heading, *aspect])?;
                }
                Event::Step {
                    dt,
                    controls: c,
                    aspect,
                } => {
                    w.write_all(&[1])?;
                    f32s(w, &[*dt, *aspect])?;
                    w.write_all(&c.buttons.to_le_bytes())?;
                    w.write_all(&c.triggers)?;
                    for v in c.left.iter().chain(&c.right) {
                        w.write_all(&v.to_le_bytes())?;
                    }
                }
                Event::Suspend => w.write_all(&[2])?,
                Event::Stance { goofy } => w.write_all(&[3, u8::from(*goofy)])?,
                Event::Collision { triangles, rails } => {
                    w.write_all(&[4])?;
                    u32s(w, triangles.front)?;
                    u32s(w, triangles.back)?;
                    u32s(w, triangles.middle.len() as u32)?;
                    for t in &triangles.middle {
                        f32s(w, t.as_flattened())?;
                    }
                    u32s(w, rails.front)?;
                    u32s(w, rails.back)?;
                    u32s(w, rails.middle.len() as u32)?;
                    for r in &rails.middle {
                        u32s(w, r.len() as u32)?;
                        f32s(w, r.as_flattened())?;
                    }
                }
                Event::Gestures { picks } => {
                    w.write_all(&[5, u8::from(picks.is_some())])?;
                    for p in picks.unwrap_or_default() {
                        u32s(w, p)?;
                    }
                }
            }
        }
        Ok(())
    }

    pub fn read(r: &mut impl Read) -> io::Result<Self> {
        let bad = |what: &str| io::Error::new(io::ErrorKind::InvalidData, what.to_owned());
        if &read::<4>(r)? != MAGIC {
            return Err(bad("not a skate ride recording"));
        }
        if !matches!(read_u32(r)?, VERSION | OLD_VERSION) {
            return Err(bad("recorded by a different version of the mod"));
        }
        let mut rec = Recording::default();
        for _ in 0..read_u32(r)? {
            rec.triangles
                .push([read_point(r)?, read_point(r)?, read_point(r)?]);
        }
        let rails = read_u32(r)?;
        rec.rails = read_rails(r, rails)?;
        for _ in 0..read_u32(r)? {
            let event = match read::<1>(r)?[0] {
                0 => Event::Activate {
                    spawn: read_point(r)?,
                    heading: read_f32(r)?,
                    aspect: read_f32(r)?,
                },
                1 => {
                    let dt = read_f32(r)?;
                    let aspect = read_f32(r)?;
                    let b: [u8; 12] = read(r)?;
                    let i = |k: usize| i16::from_le_bytes([b[k], b[k + 1]]);
                    Event::Step {
                        dt,
                        aspect,
                        controls: Controls {
                            buttons: u16::from_le_bytes([b[0], b[1]]),
                            triggers: [b[2], b[3]],
                            left: [i(4), i(6)],
                            right: [i(8), i(10)],
                        },
                    }
                }
                2 => Event::Suspend,
                3 => Event::Stance {
                    goofy: read::<1>(r)?[0] != 0,
                },
                4 => {
                    let (front, back) = (read_u32(r)?, read_u32(r)?);
                    let middle = (0..read_u32(r)?)
                        .map(|_| Ok([read_point(r)?, read_point(r)?, read_point(r)?]))
                        .collect::<io::Result<_>>()?;
                    let triangles = Splice { front, back, middle };
                    let (front, back) = (read_u32(r)?, read_u32(r)?);
                    let n = read_u32(r)?;
                    let rails = Splice { front, back, middle: read_rails(r, n)? };
                    Event::Collision { triangles, rails }
                }
                5 => {
                    let some = read::<1>(r)?[0] != 0;
                    let picks = [read_u32(r)?, read_u32(r)?, read_u32(r)?, read_u32(r)?];
                    Event::Gestures {
                        picks: some.then_some(picks),
                    }
                }
                _ => return Err(bad("unknown event in the recording")),
            };
            rec.events.push(event);
        }
        Ok(rec)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_recording_reads_back_as_written() {
        let rec = Recording {
            triangles: vec![[[0., 0., 0.], [1., 0., 0.], [0., 0., 1.]]],
            rails: vec![vec![[0., 1., 0.], [2., 1., 0.]]],
            events: vec![
                Event::Activate {
                    spawn: [1., 2., 3.],
                    heading: 0.5,
                    aspect: 16. / 9.,
                },
                Event::Step {
                    dt: 1. / 60.,
                    aspect: 16. / 9.,
                    controls: Controls {
                        buttons: 0x1000,
                        triggers: [3, 255],
                        left: [-16413, -5084],
                        right: [7, -7],
                    },
                },
                Event::Suspend,
                Event::Stance { goofy: true },
            ],
        };
        let mut bytes = Vec::new();
        rec.write(&mut bytes).unwrap();
        let back = Recording::read(&mut bytes.as_slice()).unwrap();
        assert_eq!(back.triangles, rec.triangles);
        assert_eq!(back.rails, rec.rails);
        assert_eq!(back.events.len(), 4);
        let Event::Activate { spawn, heading, .. } = back.events[0] else {
            panic!("expected an activation")
        };
        assert_eq!((spawn, heading), ([1., 2., 3.], 0.5));
        let Event::Step {
            dt, controls: c, ..
        } = back.events[1]
        else {
            panic!("expected a step")
        };
        assert_eq!(dt, 1. / 60.);
        assert_eq!(
            (c.buttons, c.triggers, c.left, c.right),
            (0x1000, [3, 255], [-16413, -5084], [7, -7])
        );
        assert!(matches!(back.events[2], Event::Suspend));
        assert!(matches!(back.events[3], Event::Stance { goofy: true }));
    }

    #[test]
    fn a_splice_keeps_what_stayed_and_stores_what_changed() {
        let old = [1, 2, 3, 4, 5];
        for new in [vec![1, 2, 3, 4, 5, 6, 7], vec![1, 9, 5], vec![], vec![8], vec![1, 2, 5]] {
            let splice = Splice::between(&old, &new);
            assert_eq!(splice.apply(&old).unwrap(), new);
        }
        let appended = Splice::between(&old, &[1, 2, 3, 4, 5, 6]);
        assert_eq!((appended.front, appended.back, appended.middle), (5, 0, vec![6]));
        // Repeats can't be counted twice from both ends.
        let s = Splice::between(&[7, 7], &[7, 7, 7]);
        assert_eq!(s.apply(&[7, 7]).unwrap(), vec![7, 7, 7]);
    }

    #[test]
    fn collision_swaps_and_gesture_picks_read_back() {
        let tri = |x: f32| [[x, 0., 0.], [1., 0., 0.], [0., 0., 1.]];
        let old = vec![tri(0.), tri(1.)];
        let new = vec![tri(0.), tri(1.), tri(2.)];
        let rails_old = vec![vec![[0., 1., 0.], [2., 1., 0.]]];
        let rails_new = vec![vec![[0., 1., 0.], [2., 1., 0.]], vec![[5., 5., 5.]]];
        let rec = Recording {
            triangles: old.clone(),
            rails: rails_old.clone(),
            events: vec![
                Event::Gestures { picks: Some([1, 2, 3, 4]) },
                Event::Collision {
                    triangles: Splice::between(&old, &new),
                    rails: Splice::between(&rails_old, &rails_new),
                },
                Event::Gestures { picks: None },
            ],
        };
        let mut bytes = Vec::new();
        rec.write(&mut bytes).unwrap();
        let back = Recording::read(&mut bytes.as_slice()).unwrap();
        assert!(matches!(back.events[0], Event::Gestures { picks: Some([1, 2, 3, 4]) }));
        let Event::Collision { triangles, rails } = &back.events[1] else {
            panic!("expected a collision swap")
        };
        assert_eq!(triangles.apply(&old).unwrap(), new);
        assert_eq!(rails.apply(&rails_old).unwrap(), rails_new);
        assert!(matches!(back.events[2], Event::Gestures { picks: None }));
    }
}
