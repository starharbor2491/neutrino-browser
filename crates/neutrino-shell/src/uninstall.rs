// SPDX-License-Identifier: MPL-2.0
//! Removal scope is explicit. Caller cannot supply extra paths or shell commands.
use serde_json::{json, Value};
use std::path::{Component, Path};
pub fn paths(home: &str, data: &str) -> Result<Value, &'static str> {
    let home = Path::new(home);
    if !home.is_absolute()
        || home.parent().is_none()
        || home
            .components()
            .any(|c| matches!(c, Component::ParentDir | Component::CurDir))
    {
        return Err("Invalid home directory.");
    }
    let support = home.join("Library/Application Support/org.neutrino.browser");
    if Path::new(data) != support {
        return Err("Full uninstall only removes Neutrino’s standard data directory. This build uses a custom data location; remove that location separately.");
    }
    Ok(json!([
        support,
        home.join("Library/Caches/org.neutrino.browser"),
        home.join("Library/HTTPStorages/org.neutrino.browser"),
        home.join("Library/WebKit/org.neutrino.browser"),
        home.join("Library/Cookies/org.neutrino.browser.binarycookies"),
        home.join("Library/Preferences/org.neutrino.browser.plist"),
        home.join("Library/Saved Application State/org.neutrino.browser.savedState")
    ]))
}
pub fn service(value: &str) -> bool {
    if ["org.neutrino.browser.ai", "org.neutrino.browser.chatgpt"].contains(&value) {
        return true;
    }
    value
        .strip_prefix("org.neutrino.browser.passwords.")
        .is_some_and(|id| {
            id.len() == 36
                && id.bytes().enumerate().all(|(i, b)| {
                    if [8, 13, 18, 23].contains(&i) {
                        b == b'-'
                    } else {
                        b.is_ascii_hexdigit()
                    }
                })
        })
}
