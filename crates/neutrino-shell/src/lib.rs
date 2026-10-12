// SPDX-License-Identifier: MPL-2.0
//! The application-owned interface. macOS supplies engine views and platform services;
//! this crate owns presentation, interaction state, editing and workspace transforms.
mod render;
mod state;
pub use state::{Shell, Snapshot};
use std::ffi::{c_char, CStr, CString};

pub const CSS: &str = include_str!("../assets/shell.css");
pub const JS: &str = include_str!("../assets/shell.js");
pub fn document() -> String {
    format!(
        r#"<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'self' 'unsafe-inline'; script-src 'self'; img-src 'self' data:; connect-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'"><title>Neutrino</title><link rel="stylesheet" href="shell.css"></head><body><div id="app"></div><div id="announcer" role="status" aria-live="polite" class="sr-only"></div><script src="shell.js"></script></body></html>"#
    )
}

// Only the main-thread native host calls this ABI. Opaque pointers are never exposed
// to website code. The owned response must be freed exactly once with string_free.
#[no_mangle]
pub extern "C" fn neutrino_shell_new() -> *mut Shell {
    Box::into_raw(Box::new(Shell::default()))
}
#[no_mangle]
pub unsafe extern "C" fn neutrino_shell_free(handle: *mut Shell) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}
#[no_mangle]
pub unsafe extern "C" fn neutrino_string_free(text: *mut c_char) {
    if !text.is_null() {
        drop(CString::from_raw(text));
    }
}
#[no_mangle]
pub unsafe extern "C" fn neutrino_shell_dispatch(
    handle: *mut Shell,
    input: *const c_char,
) -> *mut c_char {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if handle.is_null() || input.is_null() {
            return Err("Missing shell request");
        }
        let bytes = CStr::from_ptr(input).to_bytes();
        if bytes.len() > 2_097_152 {
            return Err("Shell request is too large");
        }
        let request = serde_json::from_slice(bytes).map_err(|_| "Invalid shell request")?;
        Ok((*handle).dispatch(request).to_string())
    }));
    let json = match result {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => serde_json::json!({"error":error}).to_string(),
        Err(_) => r#"{"error":"The interface could not complete this action"}"#.into(),
    };
    CString::new(json).unwrap().into_raw()
}
#[no_mangle]
pub unsafe extern "C" fn neutrino_shell_asset(name: *const c_char) -> *mut c_char {
    if name.is_null() {
        return std::ptr::null_mut();
    }
    let value = match CStr::from_ptr(name).to_str() {
        Ok("shell.css") => CSS.into(),
        Ok("shell.js") => JS.into(),
        Ok("index.html") => document(),
        _ => return std::ptr::null_mut(),
    };
    CString::new(value).unwrap().into_raw()
}
