//! xex_image <default.xex> <out image.bin>: see the library.
use std::{env, fs};

use anyhow::{Result, ensure};

fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    ensure!(args.len() == 3, "usage: skate-xex <default.xex> <out image.bin>");
    let image = skate_xex::decode(&fs::read(&args[1])?)?;
    fs::write(&args[2], &image.data)?;
    println!("base={:#010x}\nsize={}", image.base, image.data.len());
    Ok(())
}
