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
    ("vivaldi", "Vivaldi", "Panels, a status bar and every option"),
];

/// Onboarding after the layout choice follows the chosen browser's own first-run
/// flow. Account and sync steps are left out: they need the vendor's service.
pub fn setup_flow(preset: &str) -> &'static [&'static str] {
    match preset {
        "arc" => &["layout", "arc-welcome", "arc-theme", "arc-import", "arc-favorites", "arc-modules", "arc-default", "arc-tour"],
        "gx" => &["layout", "gx-welcome", "gx-theme", "gx-sounds", "gx-sidebar", "gx-blocking", "gx-modules", "gx-import"],
        "vivaldi" => &["layout", "vivaldi-welcome", "vivaldi-edition", "vivaldi-modules", "vivaldi-import", "vivaldi-theme", "vivaldi-tabs", "vivaldi-blocking", "vivaldi-done"],
        "brave" => &["layout", "brave-welcome", "brave-import", "brave-shields", "brave-modules", "brave-done"],
        "chrome" => &["layout", "chrome-welcome", "chrome-theme", "chrome-modules", "chrome-default"],
        "safari" => &["layout", "safari-modules"],
        _ => &["layout", "workspace", "import", "appearance", "defaults", "modules", "ai", "review"],
    }
}

/// Sites offered as favorites in the Arc-style setup: (name, address).
pub const FAVORITE_SITES: &[(&str, &str)] = &[
    ("Gmail", "https://mail.google.com/"),
    ("Calendar", "https://calendar.google.com/"),
    ("YouTube", "https://www.youtube.com/"),
    ("GitHub", "https://github.com/"),
    ("Notion", "https://www.notion.so/"),
    ("Figma", "https://www.figma.com/"),
    ("Slack", "https://app.slack.com/"),
    ("Spotify", "https://open.spotify.com/"),
    ("Linear", "https://linear.app/"),
    ("WhatsApp", "https://web.whatsapp.com/"),
    ("X", "https://x.com/"),
    ("Reddit", "https://www.reddit.com/"),
];
/// Tools a GX-style sidebar can show: (id, label).
pub const SIDEBAR_TOOLS: &[(&str, &str)] = &[
    ("control", "Resource control"),
    ("messengers", "Messengers"),
    ("bookmarks", "Bookmarks"),
    ("history", "History"),
    ("downloads", "Downloads"),
    ("notes", "Notes"),
    ("player", "Media player"),
];
/// Web panels a GX setup adds for its Messengers and Player choices: (title, address).
pub fn setup_web_panels(setup: &Value) -> Vec<(&'static str, &'static str)> {
    let chosen = |tool: &str| setup["preset"] == "gx" && setup["sidebarTools"].as_array().is_some_and(|l| l.iter().any(|v| v == tool));
    let mut out = vec![];
    if chosen("messengers") {
        out.extend([("WhatsApp", "https://web.whatsapp.com/"), ("Telegram", "https://web.telegram.org/"), ("Messenger", "https://www.messenger.com/"), ("Discord", "https://discord.com/app")]);
    }
    if chosen("player") {
        out.extend([("Spotify", "https://open.spotify.com/"), ("YouTube Music", "https://music.youtube.com/")]);
    }
    out
}
/// Opera GX's named color themes, applied as a custom accent.
pub const GX_THEMES: &[(&str, &str)] = &[
    ("GX Classic", "fa1e4e"),
    ("Ultraviolet", "8f44fd"),
    ("Hackerman", "1ed760"),
    ("Lambda", "ff6a00"),
    ("Frutti di mare", "1ec8e6"),
    ("Rose quartz", "ff6fa8"),
];
/// Vivaldi's bundled themes: (id, label, color mode, accent hex).
pub const VIVALDI_THEMES: &[(&str, &str, &str, &str)] = &[
    ("vivaldi", "Vivaldi", "light", "ef3939"),
    ("dark", "Dark", "dark", "ef3939"),
    ("blueprint", "Blueprint", "dark", "4a90d9"),
    ("subtle", "Subtle", "light", "6a7f99"),
    ("system", "Match system", "system", "ef3939"),
];

/// The configuration a finished setup applies, shared by the macOS host and tests.
pub fn setup_configuration(setup: &Value) -> Value {
    let id = setup["preset"].as_str().filter(|p| PRESETS.iter().any(|x| x.0 == *p)).unwrap_or("neutrino");
    let mut c = preset(id).unwrap_or_default();
    if let Some(accent) = setup["accent"].as_str().filter(|a| ["purple", "blue", "teal", "orange", "pink"].contains(a)) {
        c["theme"]["accent"] = json!(accent);
    }
    if let Some(mode) = setup["appearance"].as_str().filter(|m| ["system", "light", "dark"].contains(m)) {
        c["theme"]["colorMode"] = json!(mode);
    }
    if let Some(tabs) = setup["layout"].as_str().filter(|t| ["leading", "trailing", "top", "bottom"].contains(t)) {
        c["layout"]["tabs"] = json!(tabs);
    }
    if let Some(hex_value) = setup["accentHex"].as_str().filter(|h| hex(h)) {
        c["theme"]["accentHex"] = json!(hex_value.trim_start_matches('#'));
    }
    if id == "gx" {
        c["theme"]["sounds"] = json!(setup["sounds"].as_bool().unwrap_or(true));
        // The sidebar shows the panels chosen in setup; messengers and the player become web panels.
        let chosen: Vec<&str> = SIDEBAR_TOOLS.iter().map(|t| t.0).filter(|t| !["messengers", "player"].contains(t) && setup["sidebarTools"].as_array().is_some_and(|l| l.iter().any(|v| v == t))).collect();
        c["layout"]["panelItems"] = if chosen.is_empty() { json!(["none"]) } else { json!(chosen) };
    }
    if id == "vivaldi" {
        let edition = setup["edition"].as_str().unwrap_or("classic");
        c["layout"]["statusBar"] = json!(edition != "essentials");
        c["layout"]["panelBar"] = json!(edition != "essentials");
        c["layout"]["bookmarksBar"] = json!(edition == "full");
        c["layout"]["pageTools"] = json!(if edition == "full" { "toolbar" } else { "menu" });
    }
    c["theme"] = normalize_theme(c["theme"].clone());
    c["layout"] = normalize_layout(c["layout"].clone());
    c
}

pub fn preset(id: &str) -> Option<Value> {
    if !PRESETS.iter().any(|p| p.0 == id) {
        return None;
    }
    let horizontal = matches!(id, "chrome" | "safari" | "brave" | "gx" | "vivaldi");
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
            config["theme"]["accentHex"] = json!("fa1e4e");
            config["theme"]["iconPack"] = json!("precision");
            config["theme"]["cornerRadius"] = json!(4.);
            config["layout"]["panelBar"] = json!(true);
        }
        "vivaldi" => {
            config["theme"]["colorMode"] = json!("system");
            config["theme"]["accentHex"] = json!("ef3939");
            config["theme"]["cornerRadius"] = json!(6.);
            config["layout"]["panelBar"] = json!(true);
            config["layout"]["statusBar"] = json!(true);
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
    if l["pageTools"].as_str().is_some_and(|v| !["menu", "toolbar"].contains(&v)) {
        l["pageTools"] = Value::Null;
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
