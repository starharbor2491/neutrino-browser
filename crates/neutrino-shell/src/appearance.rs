// SPDX-License-Identifier: MPL-2.0
//! One source of truth for presets and editable appearance, shared with macOS.
use serde_json::{json, Value};

pub const PRESETS: &[(&str, &str, &str)] = &[
    (
        "neutrino",
        "Neutrino",
        "Sidebar, Spaces, and a quiet canvas",
    ),
    ("arc", "Arc", "Vertical tabs and command-first browsing"),
    ("chrome", "Chrome", "Top tabs, address bar, and bookmarks"),
    ("safari", "Safari", "Compact tabs and a light toolbar"),
    ("brave", "Brave", "Familiar top tabs with privacy controls"),
    (
        "gx",
        "Opera GX",
        "Dark workspace and visible resource tools",
    ),
];

pub fn preset(id: &str) -> Option<Value> {
    if !PRESETS.iter().any(|p| p.0 == id) {
        return None;
    }
    let horizontal = matches!(id, "chrome" | "safari" | "brave");
    let mut config = json!({
        "theme":{"design":"graphite","colorMode":"dark","accent":"purple","density":"comfortable","cornerRadius":8.,"transparency":false,"reducedMotion":false,"iconPack":"outline","iconStroke":1.7,"preset":id},
        "layout":{"tabs":if horizontal{"top"}else{"leading"},"navigation":"top","sidebar":"trailing","sidebarWidth":300.,"tabsWidth":248.,"bookmarksBar":id=="chrome","statusBar":false,"treeTabs":false}
    });
    match id {
        "arc" => {
            config["theme"]["cornerRadius"] = json!(10.);
            config["theme"]["accent"] = json!("blue");
        }
        "chrome" => {
            config["theme"]["colorMode"] = json!("light");
            config["theme"]["accent"] = json!("blue");
        }
        "safari" => {
            config["theme"]["colorMode"] = json!("system");
            config["theme"]["density"] = json!("compact");
            config["theme"]["iconPack"] = json!("precision");
        }
        "brave" => {
            config["theme"]["accent"] = json!("orange");
        }
        "gx" => {
            config["theme"]["accent"] = json!("pink");
            config["theme"]["iconPack"] = json!("precision");
            config["theme"]["cornerRadius"] = json!(4.);
            config["layout"]["secondaryPanel"] = json!("resources");
        }
        _ => {}
    }
    Some(config)
}

fn number(value: &mut Value, key: &str, min: f64, max: f64, default: f64, required: bool) {
    if required || !value[key].is_null() {
        value[key] = json!(value[key]
            .as_f64()
            .filter(|n| n.is_finite())
            .unwrap_or(default)
            .clamp(min, max));
    }
}
pub fn hex(value: &str) -> bool {
    let value = value.strip_prefix('#').unwrap_or(value);
    value.len() == 6 && value.bytes().all(|b| b.is_ascii_hexdigit())
}
pub fn normalize_theme(mut t: Value) -> Value {
    number(&mut t, "cornerRadius", 0., 24., 6., true);
    for (key, min, max, default) in [
        ("fontScale", 0.85, 1.4, 1.),
        ("spacingScale", 0.75, 1.5, 1.),
        ("borderWidth", 0., 2., 1.),
        ("shadowStrength", 0., 1., 0.),
        ("iconStroke", 1., 2.5, 1.7),
    ] {
        number(&mut t, key, min, max, default, false);
    }
    for key in ["accentHex", "surfaceHex", "textHex"] {
        if t[key].as_str().is_some_and(|v| !hex(v)) {
            t[key] = Value::Null;
        }
    }
    if t["surfaceHex"].is_null() != t["textHex"].is_null() {
        t["surfaceHex"] = Value::Null;
        t["textHex"] = Value::Null;
    }
    if t["iconPack"]
        .as_str()
        .is_some_and(|v| !["outline", "precision", "solid", "module"].contains(&v))
    {
        t["iconPack"] = json!("outline");
    }
    for key in [
        "tabsAppearance",
        "navigationAppearance",
        "sidebarAppearance",
    ] {
        if t[key].is_object() {
            number(&mut t[key], "cornerRadius", 0., 24., 10., false);
            number(&mut t[key], "fontScale", 0.85, 1.4, 1., false);
        }
    }
    t
}
pub fn normalize_layout(mut l: Value) -> Value {
    number(&mut l, "sidebarWidth", 180., 360., 240., true);
    for (key, min, max, default) in [
        ("addressWidth", 0.4, 1., 1.),
        ("tabsWidth", 200., 340., 248.),
    ] {
        number(&mut l, key, min, max, default, false);
    }
    if l["treeTabs"] == true && matches!(l["tabs"].as_str(), Some("top" | "bottom")) {
        l["tabs"] = json!("leading");
    }
    if l["secondaryPanel"]
        .as_str()
        .is_some_and(|v| !["bookmarks", "history", "downloads", "notes", "resources"].contains(&v))
    {
        l["secondaryPanel"] = Value::Null;
    }
    if let Some(components) = l["toolbarComponents"].as_array_mut() {
        let mut ids = std::collections::HashSet::new();
        let mut commands = std::collections::HashSet::new();
        components.retain(|c| {
            ids.insert(c["id"].clone().to_string())
                && (c["command"] == "separator"
                    || commands.insert(c["command"].clone().to_string()))
        });
        components.truncate(32);
    }
    l
}
