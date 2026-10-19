// SPDX-License-Identifier: MPL-2.0
//! The application-owned interface. macOS supplies engine views and platform services;
//! this crate owns presentation, interaction state, editing and workspace transforms.
mod appearance;
mod bookmarks;
mod browser_import;
mod core;
mod feeds;
mod features;
mod icons;
mod module_repository;
mod modules;
mod onboarding;
mod policy;
mod storage;
mod uninstall;
mod workspace;
pub mod workers;
pub use core::request as core_request;
mod render;
mod state;
mod views;
pub use state::{Shell, Snapshot};
use std::ffi::{c_char, CStr, CString};

pub const LOGO: &str = include_str!("../../../neutrino.svg");
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
        if bytes.len() > 8_388_608 {
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
        Ok("neutrino.svg") => LOGO.into(),
        Ok("shell.css") => CSS.into(),
        Ok("shell.js") => JS.into(),
        Ok("index.html") => document(),
        _ => return std::ptr::null_mut(),
    };
    CString::new(value).unwrap().into_raw()
}

/// Executes a bounded, stateless portable-core request.
/// # Safety
/// `input` must point to a valid NUL-terminated UTF-8 buffer for the call.
/// The returned string must be released once with `neutrino_string_free`.
#[no_mangle]
pub unsafe extern "C" fn neutrino_core_request(input: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if input.is_null() {
            return Err("Missing core request");
        }
        let bytes = CStr::from_ptr(input).to_bytes();
        if bytes.len() > 64 * 1024 * 1024 {
            return Err("Core request is too large");
        }
        core::request(serde_json::from_slice(bytes).map_err(|_| "Invalid core request")?)
    });
    let response = match result {
        Ok(Ok(value)) => serde_json::json!({"value":value}),
        Ok(Err(error)) => serde_json::json!({"error":error}),
        Err(_) => serde_json::json!({"error":"The browser operation failed"}),
    };
    CString::new(response.to_string()).unwrap().into_raw()
}

/// Searches a borrowed note field without serializing its body into UI state.
/// # Safety
/// Each nonempty buffer must be readable for its supplied length during the call.
#[no_mangle]
pub unsafe extern "C" fn neutrino_text_contains(
    text: *const c_char,
    text_length: usize,
    query: *const c_char,
    query_length: usize,
) -> bool {
    if text_length > 1_048_576 || query_length > 1_024 || text.is_null() || query.is_null() {
        return false;
    }
    let Ok(text) = std::str::from_utf8(std::slice::from_raw_parts(text.cast(), text_length)) else {
        return false;
    };
    let Ok(query) = std::str::from_utf8(std::slice::from_raw_parts(query.cast(), query_length)) else {
        return false;
    };
    let fold = |value: &str| {
        value.split_whitespace().fold(String::with_capacity(value.len()), |mut result, word| {
            if !result.is_empty() { result.push(' '); }
            result.push_str(word);
            result
        }).to_lowercase()
    };
    let query = fold(query);
    query.is_empty() || fold(text).contains(&query)
}

/// Hashes caller-owned bytes without JSON copies or a platform-specific digest.
/// # Safety
/// For nonzero length, data must point to length readable bytes for this call.
/// Release the returned string with neutrino_string_free.
#[no_mangle]
pub unsafe extern "C" fn neutrino_sha256(data: *const u8, length: usize) -> *mut c_char {
    use sha2::{Digest, Sha256};
    if length > isize::MAX as usize || data.is_null() && length > 0 {
        return std::ptr::null_mut();
    }
    let bytes = if length == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(data, length)
    };
    CString::new(format!("{:x}", Sha256::digest(bytes)))
        .unwrap()
        .into_raw()
}
