//! Engine-side glue between Garry's Mod and the headless Skate 3 host:
//! Source collision in, Skate collision and grind rails out.

pub mod calm;
pub mod collision;
pub mod float_mode;
pub mod rails;
pub mod surfaces;
pub mod repro;
pub mod world;

pub use skate_host::{bridge, hall_of_meat};
