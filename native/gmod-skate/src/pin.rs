//! Keeps this library loaded until the game exits.
//!
//! Garry's Mod unloads binary modules whenever the Lua state closes, such as
//! on every map change. The gamepad library runs polling threads that never
//! stop, so unloading the code under them crashes the game. Pinned, the
//! library stays; the next map's `require` simply opens it again.

use std::ffi::c_void;

#[cfg(windows)]
pub fn pin() -> bool {
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetModuleHandleExW(flags: u32, name: *const u16, module: *mut *mut c_void) -> i32;
    }
    const PIN: u32 = 0x1;
    const FROM_ADDRESS: u32 = 0x4;
    let mut module = std::ptr::null_mut();
    let address = pin as *const () as *const u16;
    unsafe { GetModuleHandleExW(PIN | FROM_ADDRESS, address, &mut module) != 0 }
}

#[cfg(unix)]
pub fn pin() -> bool {
    unsafe {
        let mut info: libc::Dl_info = std::mem::zeroed();
        if libc::dladdr(pin as *const c_void, &mut info) == 0 || info.dli_fname.is_null() {
            return false;
        }
        // Never closed: this extra, undeletable reference is the point.
        !libc::dlopen(
            info.dli_fname,
            libc::RTLD_NOW | libc::RTLD_NOLOAD | libc::RTLD_NODELETE,
        )
        .is_null()
    }
}
