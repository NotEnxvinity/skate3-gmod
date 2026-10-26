//! The audio decoder and the executable reader as plain C functions, so setup
//! (a Python script on the player's machine) can call them out of the module
//! it already ships for every platform, instead of needing a second program
//! built and packaged for each. Each returns 0 for success; on failure
//! `s3gm_last_error` copies the reason out.

use std::ffi::{CStr, c_char};
use std::sync::Mutex;

static LAST: Mutex<String> = Mutex::new(String::new());

fn text(p: *const c_char) -> Result<String, String> {
    if p.is_null() {
        return Err("a null path".into());
    }
    // SAFETY: the caller passes NUL-terminated strings.
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .map(str::to_owned)
        .map_err(|_| "a path that isn't UTF-8".to_string())
}

fn run(job: impl FnOnce() -> Result<String, String>) -> i32 {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(job))
        .unwrap_or_else(|_| Err("the decoder crashed".into()));
    let (code, message) = match result {
        Ok(note) => (0, note),
        Err(e) => (1, e),
    };
    if let Ok(mut last) = LAST.lock() {
        *last = message;
    }
    code
}

/// Decodes the jobs listed in `jobs` (NAME OFFSET SAMPLES CHANNELS RATE per
/// line) out of the bank `file` into `outdir`/NAME.xma16.
#[unsafe(no_mangle)]
pub extern "C" fn s3gm_xma_jobs(
    file: *const c_char,
    jobs: *const c_char,
    outdir: *const c_char,
) -> i32 {
    run(|| skate_xma::cli::run_jobs(&text(file)?, &text(jobs)?, &text(outdir)?))
}

/// Decodes the standalone SNR stream at `offset` in `file` into `out`.
#[unsafe(no_mangle)]
pub extern "C" fn s3gm_xma_snr(file: *const c_char, offset: u64, out: *const c_char) -> i32 {
    run(|| skate_xma::cli::run_snr(&text(file)?, offset as usize, &text(out)?))
}

/// Decodes the disc's default.xex to its in-memory image at `out`.
#[unsafe(no_mangle)]
pub extern "C" fn s3gm_xex_image(xex: *const c_char, out: *const c_char) -> i32 {
    run(|| {
        let bytes = std::fs::read(text(xex)?).map_err(|e| e.to_string())?;
        let image = skate_xex::decode(&bytes).map_err(|e| e.to_string())?;
        std::fs::write(text(out)?, &image.data).map_err(|e| e.to_string())?;
        Ok(format!(
            "base={:#010x} size={}",
            image.base,
            image.data.len()
        ))
    })
}

/// Copies the last call's message (the failure's reason, or the decoder's
/// note) into `buffer`, NUL-terminated, and returns its length.
#[unsafe(no_mangle)]
pub extern "C" fn s3gm_last_error(buffer: *mut u8, capacity: usize) -> usize {
    let message = LAST.lock().map(|m| m.clone()).unwrap_or_default();
    if buffer.is_null() || capacity == 0 {
        return message.len();
    }
    let n = message.len().min(capacity - 1);
    // SAFETY: the caller owns `capacity` writable bytes at `buffer`.
    unsafe {
        std::ptr::copy_nonoverlapping(message.as_ptr(), buffer, n);
        *buffer.add(n) = 0;
    }
    n
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    fn message() -> String {
        let mut buffer = vec![0u8; 256];
        let n = s3gm_last_error(buffer.as_mut_ptr(), buffer.len());
        String::from_utf8_lossy(&buffer[..n]).into_owned()
    }

    #[test]
    fn a_missing_file_fails_with_a_reason() {
        let file = CString::new("/nowhere/bank.abk").unwrap();
        let jobs = CString::new("/nowhere/jobs.txt").unwrap();
        let out = CString::new("/nowhere").unwrap();
        assert_eq!(s3gm_xma_jobs(file.as_ptr(), jobs.as_ptr(), out.as_ptr()), 1);
        assert!(message().contains("bank.abk"), "{}", message());
        assert_eq!(s3gm_xex_image(std::ptr::null(), out.as_ptr()), 1);
        assert!(message().contains("null"));
    }

    #[test]
    fn a_stream_past_the_end_is_refused() {
        let dir = std::env::temp_dir().join("s3gm-tools-test");
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("s.snr");
        std::fs::write(&file, [0u8; 16]).unwrap();
        let file = CString::new(file.to_str().unwrap()).unwrap();
        let out = CString::new(dir.join("o.xma16").to_str().unwrap()).unwrap();
        assert_eq!(s3gm_xma_snr(file.as_ptr(), 99, out.as_ptr()), 1);
        assert!(message().contains("past end"));
    }
}
