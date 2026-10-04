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
const VERSION: u32 = 1;
/// Events kept per session: half an hour of frames at 60 a second.
pub const MAX_EVENTS: usize = 108_000;

#[derive(Clone, Copy)]
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
            match *e {
                Event::Activate {
                    spawn,
                    heading,
                    aspect,
                } => {
                    w.write_all(&[0])?;
                    f32s(w, &spawn)?;
                    f32s(w, &[heading, aspect])?;
                }
                Event::Step {
                    dt,
                    controls: c,
                    aspect,
                } => {
                    w.write_all(&[1])?;
                    f32s(w, &[dt, aspect])?;
                    w.write_all(&c.buttons.to_le_bytes())?;
                    w.write_all(&c.triggers)?;
                    for v in c.left.iter().chain(&c.right) {
                        w.write_all(&v.to_le_bytes())?;
                    }
                }
                Event::Suspend => w.write_all(&[2])?,
            }
        }
        Ok(())
    }

    pub fn read(r: &mut impl Read) -> io::Result<Self> {
        let bad = |what: &str| io::Error::new(io::ErrorKind::InvalidData, what.to_owned());
        if &read::<4>(r)? != MAGIC {
            return Err(bad("not a skate ride recording"));
        }
        if read_u32(r)? != VERSION {
            return Err(bad("recorded by a different version of the mod"));
        }
        let mut rec = Recording::default();
        for _ in 0..read_u32(r)? {
            rec.triangles
                .push([read_point(r)?, read_point(r)?, read_point(r)?]);
        }
        for _ in 0..read_u32(r)? {
            let n = read_u32(r)?;
            rec.rails
                .push((0..n).map(|_| read_point(r)).collect::<io::Result<_>>()?);
        }
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
            ],
        };
        let mut bytes = Vec::new();
        rec.write(&mut bytes).unwrap();
        let back = Recording::read(&mut bytes.as_slice()).unwrap();
        assert_eq!(back.triangles, rec.triangles);
        assert_eq!(back.rails, rec.rails);
        assert_eq!(back.events.len(), 3);
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
    }
}
