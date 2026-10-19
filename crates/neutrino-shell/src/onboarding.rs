// SPDX-License-Identifier: MPL-2.0
//! First-run flows that follow the browser a person chose as their starting
//! layout. Steps that need that vendor's account or cloud service are omitted.
use crate::appearance::{setup_flow, FAVORITE_SITES, GX_THEMES, SIDEBAR_TOOLS, VIVALDI_THEMES};
use crate::render::{icon, segments, swatches};
use crate::state::{array, flag, text, Shell};
use maud::{html, Markup};
use serde_json::Value;

/// Browsers whose bookmarks and history can be read from this Mac.
pub const IMPORT_SOURCES: &[(&str, &str)] = &[
    ("chrome", "Google Chrome"),
    ("safari", "Safari"),
    ("firefox", "Firefox"),
    ("edge", "Microsoft Edge"),
    ("brave", "Brave"),
    ("arc", "Arc"),
    ("vivaldi", "Vivaldi"),
    ("opera", "Opera"),
    ("operagx", "Opera GX"),
];

pub fn render(s: &Shell) -> Markup {
    let preset = text(&s.setup, "preset");
    let flow = setup_flow(preset);
    let id = flow.get(s.step).copied().unwrap_or("layout");
    let last = s.step + 1 >= flow.len();
    let primary = match id {
        _ if last => match preset {
            "arc" => "Start browsing",
            "vivaldi" | "chrome" => "Done",
            _ => "Finish",
        },
        "arc-welcome" | "chrome-welcome" | "brave-welcome" | "vivaldi-welcome" | "gx-welcome" => "Get started",
        "safari-modules" => "Open Neutrino",
        "arc-import" | "gx-import" | "vivaldi-import" | "brave-import" if !flag(&s.snapshot, "imported") => "Skip",
        "arc-default" | "chrome-default" if !flag(&s.snapshot, "isDefaultBrowser") => "Not now",
        _ => "Continue",
    };
    html! {main class=(format!("mimic-onboarding flow-{preset} step-{id}")) data-flow=(preset) {
        div class="setup-drag" data-window-drag="true"{}
        section class="mimic-stage" aria-live="polite" {(step(s, id))}
        footer class="mimic-footer" {
            (crate::render::feedback(s))
            div class="mimic-progress" role="progressbar" aria-label="Setup progress" aria-valuemin="1" aria-valuemax=(flow.len() - 1) aria-valuenow=(s.step) {
                @for i in 1..flow.len() {span class=(if i == s.step {"current"} else if i < s.step {"done"} else {""}){}}
            }
            div class="mimic-actions" {
                @if s.step > 0 {button class="mimic-back" data-op="setup-back" disabled[s.setup_busy]{(icon("back"))"Back"}}
                span class="spacer"{}
                button class="mimic-primary" data-op=(if last {"setup-finish"} else {"setup-next"}) disabled[s.setup_busy]{(if s.setup_busy {"Saving…"} else {primary})}
            }
        }
    }}
}

fn heading(title: &str, detail: &str) -> Markup {
    html! {header class="mimic-heading"{h1 id="setup-heading" tabindex="-1"{(title)}@if !detail.is_empty(){p{(detail)}}}}
}

fn choice(op: &str, key: &str, value: &str, selected: bool, body: Markup) -> Markup {
    html! {button class=(if selected {"mimic-choice selected"} else {"mimic-choice"}) data-op=(op) data-key=[(!key.is_empty()).then_some(key)] data-value=(value) aria-pressed=(selected.to_string()){(body)}}
}

fn mark(name: &str, tone: usize) -> Markup {
    html! {span class=(format!("site-icon site-color-{}", tone % 6)) aria-hidden="true"{(name.chars().next().unwrap_or('N'))}}
}

fn import_list(s: &Shell) -> Markup {
    let done = text(&s.snapshot, "importedFrom");
    html! {
        div class="mimic-list" role="list" {
            @for (index, (id, name)) in IMPORT_SOURCES.iter().enumerate() {
                button class=(if done == *id {"mimic-row selected"} else {"mimic-row"}) role="listitem" data-op="importBrowser" data-value=(id) {
                    (mark(name, index)) span{(name)}
                    @if done == *id {(icon("check"))} @else {span class="mimic-row-action"{"Import"}}
                }
            }
            button class="mimic-row" role="listitem" data-op="importBookmarks" {span class="site-icon blank-icon"{(icon("download"))}span{"A bookmarks file (HTML)"}span class="mimic-row-action"{"Choose…"}}
        }
        @if !text(&s.snapshot, "importStatus").is_empty() {p class="mimic-note" role="status"{(text(&s.snapshot, "importStatus"))}}
    }
}

fn default_browser(s: &Shell) -> Markup {
    html! {
        @if flag(&s.snapshot, "isDefaultBrowser") {p class="mimic-note done"{(icon("check"))"Neutrino is your default browser."}}
        @else {button class="mimic-cta" data-op="defaultBrowser"{"Set as default browser"}}
        @if !text(&s.snapshot, "defaultStatus").is_empty() && !flag(&s.snapshot, "isDefaultBrowser") {p class="mimic-note"{(text(&s.snapshot, "defaultStatus"))}}
    }
}

fn blocking(s: &Shell, labels: [(&str, &str, &str); 3]) -> Markup {
    let level = if !flag(&s.setup, "blockTrackers") {
        "none"
    } else if flag(&s.setup, "blockAds") {
        "ads"
    } else {
        "trackers"
    };
    html! {div class="mimic-options" role="radiogroup" {
        @for (value, title, detail) in labels {
            (choice("setup-blocking", "", value, level == value, html! {span class="mimic-radio"{}span{strong{(title)}small{(detail)}}}))
        }
    }}
}

fn step(s: &Shell, id: &str) -> Markup {
    let setup = &s.setup;
    match id {
        // Arc
        "arc-welcome" => html! {div class="arc-orb" aria-hidden="true"{}(heading("Welcome.", "Let’s set up your browser. It takes about a minute."))},
        "arc-theme" => html! {
            (heading("Pick a color for your Space", "Every Space can have its own color. Change it any time from the Space menu."))
            div class="arc-preview" aria-hidden="true"{div class="arc-preview-bar"{i{}i{}i{}}div class="arc-preview-row selected"{}div class="arc-preview-row"{}div class="arc-preview-row"{}}
            (swatches(s, true))
            (segments("setup-field", "appearance", text(setup, "appearance"), &[("light", "Light"), ("dark", "Dark"), ("system", "Auto")]))
        },
        "arc-import" => html! {(heading("Bring your stuff", "Import bookmarks and history from the browser you use now."))(import_list(s))},
        "arc-favorites" => html! {
            (heading("Choose your favorites", "Favorites sit at the top of your sidebar, one click away."))
            div class="arc-favorites" {@for (index, (name, url)) in FAVORITE_SITES.iter().enumerate() {
                @let selected = array(&setup["favorites"]).iter().any(|v| v == url);
                (choice("setup-favorite", "", url, selected, html! {(mark(name, index))span{(name)}}))
            }}
        },
        "arc-default" => html! {(heading("Make it your default browser", "Links you open from Mail, Slack and other apps will open here."))(default_browser(s))},
        "arc-tour" => html! {
            (heading("Meet the sidebar", "Everything lives on the left. These shortcuts get you around."))
            dl class="mimic-keys" {
                div{dt{kbd{"⌘T"}}dd{"Search, or open a site"}}
                div{dt{kbd{"⌘K"}}dd{"Find an open tab or a command"}}
                div{dt{kbd{"⌘B"}}dd{"Show or hide the sidebar"}}
                div{dt{kbd{"⌘D"}}dd{"Bookmark the page"}}
                div{dt{kbd{"⌃⌥ ← →"}}dd{"Switch Spaces"}}
            }
        },
        // Opera GX
        "gx-welcome" => html! {(heading("Welcome to your new browser", "Set your colors, sounds, sidebar and blocking. You can change all of it later."))},
        "gx-theme" => html! {
            (heading("Choose your colors", "Your accent color appears on tabs, controls and the sidebar."))
            div class="gx-themes" {@for (name, hex) in GX_THEMES {
                (choice("setup-field", "accentHex", hex, text(setup, "accentHex") == *hex, html! {span class="gx-swatch" style=(format!("--swatch:#{hex}")){}span{(name)}}))
            }}
            (segments("setup-field", "appearance", text(setup, "appearance"), &[("dark", "Dark"), ("light", "Light")]))
        },
        "gx-sounds" => html! {
            (heading("Browser sounds", "Short sounds for clicks, typing and tab changes."))
            (crate::render::toggle("Browser sounds", "Plays through your Mac’s speakers at a low volume.", "sounds", flag(setup, "sounds"), true))
            button class="mimic-cta quiet" type="button" data-sound-sample="true"{(icon("activity"))"Play a sample"}
        },
        "gx-sidebar" => html! {
            (heading("Set up your sidebar", "Pick what appears in the strip on the left. Messengers open in a panel beside the page."))
            div class="mimic-options" {@for (tool, label) in SIDEBAR_TOOLS {
                @let on = array(&setup["sidebarTools"]).iter().any(|v| v == tool);
                (choice("setup-tool", "", tool, on, html! {span class="mimic-check"{@if on {(icon("check"))}}span{strong{(label)}}}))
            }}
        },
        "gx-blocking" => html! {
            (heading("Block ads and trackers", "Blocking makes pages load faster and stops sites following you around."))
            (blocking(s, [("ads", "Block ads and trackers", "Recommended"), ("trackers", "Block trackers only", "Ads still show"), ("none", "Don’t block", "Pages load as their owners intended")]))
        },
        "gx-import" => html! {(heading("Import your data", "Bring bookmarks and history over from another browser."))(import_list(s))},
        // Vivaldi
        "vivaldi-welcome" => html! {(heading("Welcome", "Let’s make the browser fit the way you work. This takes a few steps."))},
        "vivaldi-edition" => html! {
            (heading("Choose your layout", "Start simple or with everything turned on. You can change any of it in Settings."))
            div class="vivaldi-editions" {
                @for (value, title, detail) in [("essentials", "Essentials", "Tabs, the address bar and a start page."), ("classic", "Classic", "Adds the Panel bar for bookmarks, history and notes, and a status bar."), ("full", "Fully Loaded", "Everything: panels, status bar, bookmarks bar and page tools in the toolbar.")] {
                    (choice("setup-field", "edition", value, text(setup, "edition") == value, html! {span class=(format!("edition-art edition-{value}")) aria-hidden="true"{i class="art-tabs"{}i class="art-panel"{}i class="art-status"{}}strong{(title)}small{(detail)}}))
                }
            }
        },
        "vivaldi-import" => html! {(heading("Import from another browser", "Bring over your bookmarks and history."))(import_list(s))},
        "vivaldi-theme" => html! {
            (heading("Choose a theme", "Themes change the browser’s colors. Make your own later in Settings."))
            div class="vivaldi-themes" {@for (value, title, mode, hex) in VIVALDI_THEMES {
                (choice("setup-field", "theme", value, text(setup, "theme") == *value, html! {span class=(format!("theme-art mode-{mode}")) style=(format!("--swatch:#{hex}")) aria-hidden="true"{i{}i{}}span{(title)}}))
            }}
        },
        "vivaldi-tabs" => html! {
            (heading("Where should your tabs go?", "Put the tab bar on any side of the window."))
            div class="vivaldi-positions" {@for (value, title) in [("top", "Top"), ("bottom", "Bottom"), ("leading", "Left"), ("trailing", "Right")] {
                (choice("setup-field", "layout", value, text(setup, "layout") == value, html! {span class=(format!("position-art at-{value}")) aria-hidden="true"{i{}}span{(title)}}))
            }}
        },
        "vivaldi-blocking" => html! {
            (heading("Tracker and ad blocking", "Choose how much to block. You can change this for each site."))
            (blocking(s, [("none", "No blocking", "Load every page as its owner intended."), ("trackers", "Block trackers", "Stop sites following you around."), ("ads", "Block trackers and ads", "Also remove most advertising.")]))
        },
        "vivaldi-done" => html! {(heading("You’re all set", "Your browser is ready. Open Settings any time to change your choices."))(default_browser(s))},
        // Brave
        "brave-welcome" => html! {
            div class="brave-glow" aria-hidden="true"{}
            (heading("Welcome", "Let’s get you set up. Start by making this your default browser."))
            (default_browser(s))
        },
        "brave-import" => html! {(heading("Import bookmarks and settings", "Bring them over from the browser you used before."))(import_list(s))},
        "brave-shields" => html! {
            (heading("Shields", "Shields block ads and trackers on every site. Lower them for one site from the shield button in the address bar."))
            (blocking(s, [("ads", "Standard", "Blocks trackers and ads."), ("trackers", "Trackers only", "Blocks trackers; ads still show."), ("none", "Off", "Nothing is blocked.")]))
        },
        "brave-done" => html! {(heading("You’re all set", if flag(setup, "blockTrackers") {"Your Shields are up. Lower them for a site from the address bar."} else {"Shields are off. Turn them on from the shield button in the address bar."}))},
        // Chrome
        "chrome-welcome" => html! {div class="chrome-ribbon" aria-hidden="true"{i{}i{}i{}i{}}(heading("Welcome", "Set up your browser in a few quick steps."))},
        "chrome-theme" => html! {
            (heading("Make it your own", "Choose a color and a mode. You can change them later."))
            (swatches(s, true))
            (segments("setup-field", "appearance", text(setup, "appearance"), &[("light", "Light"), ("dark", "Dark"), ("system", "Device")]))
        },
        "chrome-default" => html! {(heading("Set as your default browser", "Open links from other apps here."))(default_browser(s))},
        // Every flow: the features to turn on, in that browser's words.
        "arc-modules" => html! {(heading("Choose your features", "Arc’s tools are on. Turn on anything else you want."))(module_picker(s))},
        "gx-modules" => html! {(heading("Pick your features", "GX Control, sounds and panels are ready. Add or remove anything."))(module_picker(s))},
        "vivaldi-modules" => html! {(heading("Fine-tune your features", "Your edition turned these on. Vivaldi is yours to shape: change anything."))(module_picker(s))},
        "brave-modules" => html! {(heading("Choose your features", "Turn on the tools you want. Shields stay on either way."))(module_picker(s))},
        "chrome-modules" | "safari-modules" => html! {(heading("Choose your features", "Turn on the tools you want. You can change them later."))(module_picker(s))},
        _ => html! {},
    }
}

/// Tools offered as on/off modules during setup, by role.
const TOOL_ROLES: &[&str] = &["notes", "reader", "focusMode", "screenshot", "startWidget", "menu"];
/// Roles where one module replaces another: (role, label, whether none is allowed).
const PROVIDER_ROLES: &[(&str, &str, bool)] = &[("tabSystem", "Tabs", false), ("resourceMonitor", "Resource monitor", true), ("theme", "Theme", true), ("icons", "Icons", true), ("layout", "Layout", true)];

fn bundled(s: &Shell) -> impl Iterator<Item = &Value> {
    array(&s.snapshot["modules"]).iter().filter(|m| flag(m, "bundled"))
}

/// Whether a feature or tool module is on after setup: the choice made here,
/// else the chosen browser's default.
pub fn module_on(s: &Shell, m: &Value) -> bool {
    let id = text(m, "id");
    if let Some(choice) = s.setup["modules"][id].as_bool() {
        return choice;
    }
    match id.strip_prefix("org.neutrino.").filter(|_| text(m, "capability") == "feature") {
        Some(key) => {
            let preset = text(&s.setup, "preset");
            match (preset, text(&s.setup, "edition")) {
                ("vivaldi", "essentials") => crate::features::module_default(key, "chrome"),
                ("vivaldi", "full") => key != "interface-css",
                _ => crate::features::module_default(key, preset),
            }
        }
        None => flag(m, "enabled"),
    }
}

/// The module chosen for a replaceable role, or "" for none.
pub fn provider(s: &Shell, role: &str) -> String {
    if let Some(id) = s.setup["providers"][role].as_str() {
        return id.to_string();
    }
    bundled(s).find(|m| text(m, "capability") == role && flag(m, "enabled")).map(|m| text(m, "id").to_string()).unwrap_or_default()
}

/// Every bundled module's state after setup, sent with the finished setup.
pub fn module_choices(s: &Shell) -> Value {
    let mut out = serde_json::Map::new();
    for m in bundled(s) {
        let role = text(m, "capability");
        let on = if role == "feature" || TOOL_ROLES.contains(&role) {
            module_on(s, m)
        } else if PROVIDER_ROLES.iter().any(|r| r.0 == role) {
            provider(s, role) == text(m, "id")
        } else {
            continue;
        };
        out.insert(text(m, "id").to_string(), Value::Bool(on));
    }
    Value::Object(out)
}

/// The module step: features grouped as in Modules, then tools and providers.
pub fn module_picker(s: &Shell) -> Markup {
    let features: Vec<&Value> = bundled(s).filter(|m| text(m, "capability") == "feature").collect();
    let row = |m: &Value| {
        let on = module_on(s, m);
        html! {button class="setup-module-row" data-op="setup-module" data-value=(text(m, "id")) role="switch" aria-checked=(on.to_string()) title=(text(m, "description")) {
            span{strong{(text(m, "name"))}small{(text(m, "description"))}}
            span class=(if on {"switch on"} else {"switch"}){span{}}
        }}
    };
    let mut groups: Vec<&str> = vec![];
    for (_, group, _) in crate::features::MODULES {
        if !groups.contains(group) {
            groups.push(group);
        }
    }
    let total = features.len() + bundled(s).filter(|m| TOOL_ROLES.contains(&text(m, "capability"))).count();
    let count = features.iter().filter(|m| module_on(s, m)).count() + bundled(s).filter(|m| TOOL_ROLES.contains(&text(m, "capability")) && module_on(s, m)).count();
    html! {div class="module-picker" {
        div class="module-picker-bar"{
            span{(count)" of "(total)" on"}
            span class="spacer"{}
            button class="button quiet" type="button" data-op="setup-modules" data-value="defaults"{"Use defaults"}
            button class="button quiet" type="button" data-op="setup-modules" data-value="all"{"Turn all on"}
        }
        @for group in groups {
            @let members: Vec<&&Value> = features.iter().filter(|m| crate::features::MODULES.iter().any(|f| f.1 == group && text(m, "id") == format!("org.neutrino.{}", f.0))).collect();
            @if !members.is_empty() {
                details class="module-group" {
                    summary{strong{(group)}span{(members.iter().filter(|m| module_on(s, m)).count())" of "(members.len())}(icon("down"))}
                    div class="module-rows"{@for m in members {(row(m))}}
                }
            }
        }
        details class="module-group" {
            @let tools: Vec<&Value> = bundled(s).filter(|m| TOOL_ROLES.contains(&text(m, "capability"))).collect();
            summary{strong{"Tools"}span{(tools.iter().filter(|m| module_on(s, m)).count())" of "(tools.len())}(icon("down"))}
            div class="module-rows"{@for m in tools {(row(m))}}
        }
        details class="module-group" {
            summary{strong{"Look and providers"}span{"One of each"}(icon("down"))}
            div class="module-providers"{
                @for (role, label, none) in PROVIDER_ROLES {
                    @let options: Vec<&Value> = bundled(s).filter(|m| text(m, "capability") == *role).collect();
                    @if !options.is_empty() {
                        @let current = provider(s, role);
                        @let none_label = if ["theme", "layout"].contains(role) {"Browser’s own"} else if *role == "icons" {"Built-in"} else {"Off"};
                        @let items: Vec<(String, String)> = none.then(|| (String::new(), none_label.to_string())).into_iter().chain(options.iter().map(|m| (text(m, "id").to_string(), text(m, "name").trim_end_matches(" Theme").trim_end_matches(" SVG Icons").to_string()))).collect();
                        label class="control-label"{(label)}
                        (segments("setup-provider", role, &current, &items.iter().map(|(a, b)| (a.as_str(), b.as_str())).collect::<Vec<_>>()))
                    }
                }
            }
        }
        p class="mimic-note"{"Change any of these later in Modules."}
    }}
}
