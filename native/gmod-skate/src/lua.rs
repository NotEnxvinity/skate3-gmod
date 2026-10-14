//! The slice of the LuaJIT C API this module needs, resolved at load time from
//! the `lua_shared` library Garry's Mod has already loaded into the process.
//!
//! Nothing here raises Lua errors: a Lua error unwinds with longjmp, which must
//! never cross Rust frames. Functions validate their arguments by hand and
//! return `nil, message` instead.

use std::ffi::{c_char, c_int, c_void};
use std::sync::OnceLock;

pub type State = *mut c_void;
pub type CFunction = unsafe extern "C" fn(State) -> c_int;

/// Lua 5.1's pseudo-index for the globals table.
pub const GLOBALS: c_int = -10002;
pub const TNUMBER: c_int = 3;
pub const TSTRING: c_int = 4;
pub const TTABLE: c_int = 5;

macro_rules! api {
    ($($name:ident: fn($($arg:ty),*) $(-> $ret:ty)?;)*) => {
        #[allow(non_snake_case)]
        pub struct Api {
            _library: libloading::Library,
            $(pub $name: unsafe extern "C" fn($($arg),*) $(-> $ret)?,)*
        }
        impl Api {
            unsafe fn resolve(library: libloading::Library) -> Result<Self, String> {
                $(
                    let $name = unsafe {
                        *library
                            .get::<unsafe extern "C" fn($($arg),*) $(-> $ret)?>(
                                concat!(stringify!($name), "\0").as_bytes(),
                            )
                            .map_err(|e| format!("{}: {e}", stringify!($name)))?
                    };
                )*
                Ok(Self { _library: library, $($name,)* })
            }
        }
    };
}

api! {
    lua_gettop: fn(State) -> c_int;
    lua_settop: fn(State, c_int);
    lua_type: fn(State, c_int) -> c_int;
    lua_tonumber: fn(State, c_int) -> f64;
    lua_tolstring: fn(State, c_int, *mut usize) -> *const c_char;
    lua_objlen: fn(State, c_int) -> usize;
    lua_pushnil: fn(State);
    lua_pushnumber: fn(State, f64);
    lua_pushboolean: fn(State, c_int);
    lua_pushlstring: fn(State, *const c_char, usize);
    lua_pushcclosure: fn(State, CFunction, c_int);
    lua_createtable: fn(State, c_int, c_int);
    lua_setfield: fn(State, c_int, *const c_char);
    lua_rawgeti: fn(State, c_int, c_int);
    lua_rawseti: fn(State, c_int, c_int);
}

static API: OnceLock<Result<Api, String>> = OnceLock::new();

/// The process's already-loaded `lua_shared`, found by its library name.
pub fn api() -> Result<&'static Api, &'static str> {
    API.get_or_init(load).as_ref().map_err(String::as_str)
}

fn load() -> Result<Api, String> {
    #[cfg(windows)]
    const NAMES: &[&str] = &["lua_shared.dll"];
    #[cfg(target_os = "macos")]
    const NAMES: &[&str] = &["@executable_path/lua_shared.dylib", "lua_shared.dylib"];
    #[cfg(all(unix, not(target_os = "macos")))]
    const NAMES: &[&str] = &[
        "lua_shared.so",
        "lua_shared_client.so",
        "bin/linux64/lua_shared.so",
        "bin/linux64/lua_shared_client.so",
        "garrysmod/bin/lua_shared.so",
    ];
    let mut errors = Vec::new();
    for name in NAMES {
        match open(name) {
            Ok(library) => return unsafe { Api::resolve(library) },
            Err(e) => errors.push(format!("{name}: {e}")),
        }
    }
    Err(format!("lua_shared not found ({})", errors.join("; ")))
}

#[cfg(windows)]
fn open(name: &str) -> Result<libloading::Library, libloading::Error> {
    // Returns the module Garry's Mod already loaded, not a second copy.
    unsafe { libloading::Library::new(name) }
}

#[cfg(not(windows))]
fn open(name: &str) -> Result<libloading::Library, libloading::Error> {
    use libloading::os::unix::{Library, RTLD_LOCAL, RTLD_NOW};
    // Prefer the copy already in the process; fall back to loading by path.
    const RTLD_NOLOAD: c_int = libc::RTLD_NOLOAD;
    unsafe { Library::open(Some(name), RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD) }
        .or_else(|_| unsafe { Library::open(Some(name), RTLD_NOW | RTLD_LOCAL) })
        .map(Into::into)
}

/// A Lua stack, valid for the duration of one call from Lua.
#[derive(Clone, Copy)]
pub struct Lua {
    pub api: &'static Api,
    pub state: State,
}

impl Lua {
    pub fn top(&self) -> c_int {
        unsafe { (self.api.lua_gettop)(self.state) }
    }
    pub fn type_of(&self, index: c_int) -> c_int {
        unsafe { (self.api.lua_type)(self.state, index) }
    }
    pub fn number(&self, index: c_int) -> Option<f64> {
        (self.type_of(index) == TNUMBER)
            .then(|| unsafe { (self.api.lua_tonumber)(self.state, index) })
    }
    /// A string argument's bytes; Lua strings may hold binary data.
    pub fn bytes(&self, index: c_int) -> Option<&[u8]> {
        if self.type_of(index) != TSTRING {
            return None;
        }
        let mut len = 0;
        let ptr = unsafe { (self.api.lua_tolstring)(self.state, index, &mut len) };
        (!ptr.is_null()).then(|| unsafe { std::slice::from_raw_parts(ptr.cast::<u8>(), len) })
    }
    pub fn string(&self, index: c_int) -> Option<String> {
        self.bytes(index)
            .map(|b| String::from_utf8_lossy(b).into_owned())
    }
    /// A flat array of numbers at `index`, or `None` if it isn't a table.
    pub fn numbers(&self, index: c_int) -> Option<Vec<f32>> {
        if self.type_of(index) != TTABLE {
            return None;
        }
        let len = unsafe { (self.api.lua_objlen)(self.state, index) };
        let mut out = Vec::with_capacity(len);
        let index = if index < 0 {
            self.top() + 1 + index
        } else {
            index
        };
        for i in 1..=len as c_int {
            unsafe { (self.api.lua_rawgeti)(self.state, index, i) };
            out.push(self.number(-1).unwrap_or(0.) as f32);
            self.pop(1);
        }
        Some(out)
    }
    pub fn pop(&self, n: c_int) {
        unsafe { (self.api.lua_settop)(self.state, -n - 1) }
    }
    pub fn push_nil(&self) {
        unsafe { (self.api.lua_pushnil)(self.state) }
    }
    pub fn push_number(&self, n: f64) {
        unsafe { (self.api.lua_pushnumber)(self.state, n) }
    }
    pub fn push_bool(&self, b: bool) {
        unsafe { (self.api.lua_pushboolean)(self.state, c_int::from(b)) }
    }
    pub fn push_str(&self, s: &str) {
        unsafe { (self.api.lua_pushlstring)(self.state, s.as_ptr().cast(), s.len()) }
    }
    /// Pushes raw bytes as a Lua string (binary-safe).
    pub fn push_bytes(&self, b: &[u8]) {
        unsafe { (self.api.lua_pushlstring)(self.state, b.as_ptr().cast(), b.len()) }
    }
    pub fn push_function(&self, f: CFunction) {
        unsafe { (self.api.lua_pushcclosure)(self.state, f, 0) }
    }
    pub fn new_table(&self) {
        unsafe { (self.api.lua_createtable)(self.state, 0, 0) }
    }
    /// `t[name] = <top>` for the table at `table`, popping the value.
    pub fn set_field(&self, table: c_int, name: &std::ffi::CStr) {
        unsafe { (self.api.lua_setfield)(self.state, table, name.as_ptr()) }
    }
    /// `t[i] = <top>` for the table at `table`, popping the value.
    pub fn set_index(&self, table: c_int, i: c_int) {
        unsafe { (self.api.lua_rawseti)(self.state, table, i) }
    }
    /// Pushes `{x, y, z}` as a plain array; Lua turns it into a Vector.
    pub fn push_vec(&self, v: [f32; 3]) {
        self.new_table();
        for (i, c) in v.iter().enumerate() {
            self.push_number(f64::from(*c));
            self.set_index(-2, i as c_int + 1);
        }
    }
    /// The conventional failure return: `nil, message`.
    pub fn fail(&self, message: &str) -> c_int {
        self.push_nil();
        self.push_str(message);
        2
    }
}
