//! Engine-side glue between Garry's Mod and the headless Skate 3 host:
//! Source collision in, Skate collision and grind rails out.

pub mod collision;
pub mod rails;
pub mod world;

pub use skate_host::bridge;
