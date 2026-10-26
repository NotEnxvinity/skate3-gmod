//! The same C functions the skate module exports (native/gmod-skate/src/tools.rs,
//! included here, not copied), without the game bridge or audio output. Setup
//! loads this on an Apple-silicon Mac, where Garry's Mod and its module run as
//! Intel code under Rosetta but setup's own Python is native and can't load them.
#[path = "../../gmod-skate/src/tools.rs"]
mod tools;
