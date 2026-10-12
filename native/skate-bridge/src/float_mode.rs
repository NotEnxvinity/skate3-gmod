//! The thread that runs the simulation inherits the floating point mode of
//! the thread that started it, and the game may run with denormals flushed to
//! zero (flush-to-zero / denormals-are-zero). The engine port was checked
//! against the PC's default mode: with flushing on, vectors' unused fourth
//! lanes turn NaN and the on-foot jump fails ("Nonfinite BipedAir launch
//! packet"). `pc()` puts the calling thread back in the default mode, so the
//! game simulates exactly what skate-headless replays.

const FLUSH_TO_ZERO: u32 = 1 << 15;
const DENORMALS_ARE_ZERO: u32 = 1 << 6;
const ROUNDING: u32 = 3 << 13;

/// This thread's MXCSR (x86_64 only), to report the game's mode.
pub fn current() -> Option<u32> {
    #[cfg(target_arch = "x86_64")]
    {
        let mut csr: u32 = 0;
        unsafe { std::arch::asm!("stmxcsr [{}]", in(reg) &mut csr, options(nostack)) };
        Some(csr)
    }
    #[cfg(not(target_arch = "x86_64"))]
    None
}

/// Keep denormals and round to nearest on this thread, the PC's default.
pub fn pc() {
    #[cfg(target_arch = "x86_64")]
    if let Some(csr) = current() {
        let csr = csr & !(FLUSH_TO_ZERO | DENORMALS_ARE_ZERO | ROUNDING);
        unsafe { std::arch::asm!("ldmxcsr [{}]", in(reg) &csr, options(nostack)) };
    }
    #[cfg(target_arch = "aarch64")]
    unsafe {
        // FPCR bit 24 flushes denormals; bits 22-23 pick the rounding mode.
        let mut fpcr: u64;
        std::arch::asm!("mrs {}, fpcr", out(reg) fpcr, options(nomem, nostack));
        fpcr &= !((1 << 24) | (3 << 22));
        std::arch::asm!("msr fpcr, {}", in(reg) fpcr, options(nomem, nostack));
    }
}

#[cfg(all(test, target_arch = "x86_64"))]
mod tests {
    use std::hint::black_box;

    #[test]
    fn clears_flushing_inherited_from_the_starting_thread() {
        std::thread::spawn(|| {
            let csr = super::current().unwrap() | super::FLUSH_TO_ZERO | super::DENORMALS_ARE_ZERO;
            unsafe { std::arch::asm!("ldmxcsr [{}]", in(reg) &csr, options(nostack)) };
            assert_eq!(black_box(1e-22f32) * black_box(1e-22f32), 0.0);
            // A thread started now inherits the flushing (Linux copies it).
            std::thread::spawn(|| {
                super::pc();
                assert!(black_box(1e-22f32) * black_box(1e-22f32) > 0.0);
                assert_eq!(super::current().unwrap() & (super::FLUSH_TO_ZERO | super::DENORMALS_ARE_ZERO), 0);
            })
            .join()
            .unwrap();
        })
        .join()
        .unwrap();
    }
}
