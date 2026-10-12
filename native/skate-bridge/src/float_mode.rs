//! Skate 3 ran on the Xbox 360's vector unit, which flushes denormal floats
//! (anything smaller than about 1e-38) to zero. The engine's maths was written
//! for that: a vector that decays to a denormal length reads as zero, and the
//! zero checks catch it. On a PC the same vector keeps its tiny length, and the
//! square-root-and-refine step squares it past f32's range into NaN (the
//! "Non-finite torque" and "Nonfinite BipedAir launch packet" glitches).
//!
//! `console()` puts the calling thread's floating point unit in the 360's
//! mode: denormal results become zero and denormal inputs read as zero. Call
//! it on the thread that runs the simulation, never on the game's own threads.

/// Flush denormals to zero on this thread, like the 360.
pub fn console() {
    #[cfg(target_arch = "x86_64")]
    unsafe {
        // MXCSR bit 15 is flush-to-zero, bit 6 is denormals-are-zero.
        let mut csr: u32 = 0;
        std::arch::asm!("stmxcsr [{}]", in(reg) &mut csr, options(nostack));
        csr |= (1 << 15) | (1 << 6);
        std::arch::asm!("ldmxcsr [{}]", in(reg) &csr, options(nostack));
    }
    #[cfg(target_arch = "aarch64")]
    unsafe {
        // FPCR bit 24 flushes denormal inputs and results to zero.
        let mut fpcr: u64;
        std::arch::asm!("mrs {}, fpcr", out(reg) fpcr, options(nomem, nostack));
        fpcr |= 1 << 24;
        std::arch::asm!("msr fpcr, {}", in(reg) fpcr, options(nomem, nostack));
    }
}

#[cfg(test)]
mod tests {
    use std::hint::black_box;

    #[test]
    fn denormals_flush_to_zero_on_this_thread_only() {
        let tiny = black_box(1e-22f32);
        std::thread::spawn(move || {
            super::console();
            assert_eq!(black_box(tiny) * black_box(tiny), 0.0);
            assert_eq!(black_box(f32::from_bits(1)), 0.0);
        })
        .join()
        .unwrap();
        // Other threads keep the PC's normal behaviour.
        assert!(tiny * tiny > 0.0);
    }
}
