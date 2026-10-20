// SPDX-License-Identifier: MPL-2.0
//! Everyday browser features every style shares: tab actions, find, address
//! suggestions, page tools, per-site settings, library collections, performance
//! limits and keyboard shortcuts. Requests are validated here; the host performs
//! the resulting commands.
use crate::render::host;
use crate::state::{array, bound, flag, resolve_address, text, Shell};
use serde_json::{json, Value};
use url::Url;

/// Operations handled by this module.
pub const OPS: &[&str] = &[
    "tab-action", "rename-tab", "select-index", "tab-step", "reopen-closed", "find-open", "find-query",
    "find-step", "find-close", "address-input", "suggest-move", "suggest-accept", "page-command",
    "nav-history", "go-history", "site-setting", "clear-data", "site-data", "edit-bookmark", "reading",
    "session", "board", "web-panel", "favorite", "space-appearance", "folder-color", "nest-folder", "browser-passwords", "fake-history", "reader-speak", "delete-space",
    "delete-profile", "capture-mode", "capture-area", "markup", "split-axis", "custom-rules", "search-engine",
    "address-book", "shortcut", "chain", "run-action", "rail-peek", "setting", "record-shortcut",
    "library-filter", "board-select", "boost", "startup-pages", "split-ratio", "tidy-tabs", "link-route", "site-reset", "filter-list", "password-prompt", "move-bookmark", "tab-preview", "stack-tabs", "card", "feed", "dial-group",
];

/// Fake My History kinds: key, label, and the pages a visit can be to.
pub const FAKE_HISTORY: &[(&str, &str, &[(&str, &str)])] = &[
    ("productive", "Productive", &[
        ("Getting Things Done – Wikipedia", "https://en.wikipedia.org/wiki/Getting_Things_Done"),
        ("Pomodoro Technique – Wikipedia", "https://en.wikipedia.org/wiki/Pomodoro_Technique"),
        ("Spreadsheet – Wikipedia", "https://en.wikipedia.org/wiki/Spreadsheet"),
        ("MDN Web Docs", "https://developer.mozilla.org/en-US/"),
        ("The Rust Programming Language", "https://doc.rust-lang.org/book/"),
        ("Swift.org – Documentation", "https://www.swift.org/documentation/"),
        ("Time management – Wikipedia", "https://en.wikipedia.org/wiki/Time_management"),
        ("Inbox zero – Wikipedia", "https://en.wikipedia.org/wiki/Inbox_zero"),
    ]),
    ("learning", "Learning", &[
        ("Photosynthesis – Wikipedia", "https://en.wikipedia.org/wiki/Photosynthesis"),
        ("Roman Empire – Wikipedia", "https://en.wikipedia.org/wiki/Roman_Empire"),
        ("Linear algebra – Wikipedia", "https://en.wikipedia.org/wiki/Linear_algebra"),
        ("Khan Academy", "https://www.khanacademy.org/"),
        ("Project Gutenberg", "https://www.gutenberg.org/"),
        ("Plate tectonics – Wikipedia", "https://en.wikipedia.org/wiki/Plate_tectonics"),
        ("Byzantine Empire – Wikipedia", "https://en.wikipedia.org/wiki/Byzantine_Empire"),
        ("Periodic table – Wikipedia", "https://en.wikipedia.org/wiki/Periodic_table"),
    ]),
    ("wholesome", "Wholesome", &[
        ("Bread – Wikipedia", "https://en.wikipedia.org/wiki/Bread"),
        ("Houseplant – Wikipedia", "https://en.wikipedia.org/wiki/Houseplant"),
        ("Knitting – Wikipedia", "https://en.wikipedia.org/wiki/Knitting"),
        ("Golden Retriever – Wikipedia", "https://en.wikipedia.org/wiki/Golden_Retriever"),
        ("Birdwatching – Wikipedia", "https://en.wikipedia.org/wiki/Birdwatching"),
        ("Tea – Wikipedia", "https://en.wikipedia.org/wiki/Tea"),
        ("Hiking – Wikipedia", "https://en.wikipedia.org/wiki/Hiking"),
        ("Origami – Wikipedia", "https://en.wikipedia.org/wiki/Origami"),
    ]),
];

/// Built-in feature modules: key (the module is `org.neutrino.<key>`), group,
/// and the starting layouts that turn it on during setup ("*" for all).
pub const MODULES: &[(&str, &str, &[&str])] = &[
    ("tab-sleep", "Tabs", &["*"]),
    ("tab-previews", "Tabs", &["vivaldi", "gx", "brave", "chrome"]),
    ("tab-islands", "Tabs", &["gx"]),
    ("tab-stacks", "Tabs", &["vivaldi"]),
    ("favorites", "Tabs", &["arc"]),
    ("tidy-tabs", "Tabs", &["arc"]),
    ("peek", "Links", &["arc"]),
    ("little-arc", "Links", &["arc"]),
    ("link-routes", "Links", &["arc"]),
    ("mouse-gestures", "Links", &["vivaldi", "gx"]),
    ("command-chains", "Links", &["vivaldi"]),
    ("spatial-navigation", "Links", &["vivaldi"]),
    ("fast-forward", "Links", &["vivaldi"]),
    ("page-styles", "Pages", &["vivaldi", "gx"]),
    ("boosts", "Pages", &["arc"]),
    ("cookie-banners", "Pages", &["brave", "vivaldi", "gx", "neutrino"]),
    ("autofill", "Pages", &["*"]),
    ("password-manager", "Pages", &["*"]),
    ("forget-sites", "Pages", &["brave"]),
    ("fingerprinting", "Pages", &["brave"]),
    ("web-panels", "Workspace", &["vivaldi", "gx"]),
    ("boards", "Workspace", &["arc", "gx"]),
    ("reading-list", "Workspace", &["*"]),
    ("sessions", "Workspace", &["vivaldi"]),
    ("feeds", "Workspace", &["vivaldi"]),
    ("speed-dial", "Workspace", &["vivaldi", "gx"]),
    ("media-controls", "Media and sound", &["arc", "gx"]),
    ("break-mode", "Media and sound", &["vivaldi"]),
    ("sounds", "Media and sound", &["gx"]),
    ("limiter", "Performance", &["gx"]),
    ("panic", "Performance", &["gx"]),
    ("fake-history", "Performance", &["gx"]),
    ("wallpapers", "Look", &["gx", "vivaldi", "brave"]),
    ("theme-schedule", "Look", &["vivaldi"]),
    ("interface-css", "Look", &[]),
];

/// Whether a built-in feature module is on. A feature the host does not list
/// as a module (an older host) stays on.
pub fn on(s: &Shell, key: &str) -> bool {
    let id = format!("org.neutrino.{key}");
    array(&s.snapshot["modules"]).iter().find(|m| text(m, "id") == id).is_none_or(|m| flag(m, "enabled"))
}

/// Whether an action's feature module is on.
pub fn action_on(s: &Shell, id: &str) -> bool {
    match id {
        "sleep-tab" => on(s, "tab-sleep"),
        "reading-add" | "reading-list" => on(s, "reading-list"),
        "sessions" | "save-session" => on(s, "sessions"),
        "boards" => on(s, "boards"),
        "break" => on(s, "break-mode"),
        "fast-forward" | "rewind" => on(s, "fast-forward"),
        "panic" => on(s, "panic"),
        _ => true,
    }
}

/// Whether setup turns a feature module on for a starting layout.
pub fn module_default(key: &str, preset: &str) -> bool {
    let preset = if preset.is_empty() { "neutrino" } else { preset };
    MODULES.iter().find(|m| m.0 == key).is_some_and(|m| m.2.contains(&"*") || m.2.contains(&preset))
}

/// Actions offered by the command bar, shortcuts and command chains:
/// identifier, label, glyph, default shortcut.
pub const ACTIONS: &[(&str, &str, &str, &str)] = &[
    ("new-tab", "New tab", "plus", "cmd+t"),
    ("new-window", "New window", "window", "cmd+n"),
    ("private-window", "New private window", "shield", "shift+cmd+n"),
    ("reopen-tab", "Reopen closed tab", "undo", "shift+cmd+t"),
    ("close-tab", "Close tab", "close", "cmd+w"),
    ("next-tab", "Next tab", "forward", "ctrl+tab"),
    ("previous-tab", "Previous tab", "back", "ctrl+shift+tab"),
    ("duplicate-tab", "Duplicate tab", "copy", ""),
    ("pin-tab", "Pin or unpin tab", "pin", ""),
    ("mute-tab", "Mute or unmute tab", "volume", "ctrl+m"),
    ("sleep-tab", "Put tab to sleep", "moon", ""),
    ("split", "Split view", "split", ""),
    ("find", "Find on page", "search", "cmd+f"),
    ("reader", "Reader view", "reader", ""),
    ("print", "Print", "print", "cmd+p"),
    ("save-pdf", "Save as PDF", "download", ""),
    ("save-page", "Save page as", "download", "cmd+s"),
    ("view-source", "View page source", "code", "alt+cmd+u"),
    ("dev-tools", "Developer tools", "terminal", "alt+cmd+i"),
    ("copy-url", "Copy page address", "copy", "shift+cmd+c"),
    ("share", "Share page", "external", ""),
    ("pip", "Picture in picture", "pip", ""),
    ("capture", "Capture page", "camera", "shift+cmd+s"),
    ("bookmark", "Bookmark page", "bookmark", "cmd+d"),
    ("reading-add", "Add to Reading List", "book", "shift+cmd+d"),
    ("bookmarks", "Bookmarks", "bookmark", "alt+cmd+b"),
    ("history", "History", "history", "cmd+y"),
    ("downloads", "Downloads", "download", "alt+cmd+l"),
    ("reading-list", "Reading List", "book", ""),
    ("sessions", "Saved sessions", "folder", ""),
    ("boards", "Boards", "grid", ""),
    ("settings", "Settings", "settings", "cmd+,"),
    ("customize", "Customize", "appearance", ""),
    ("extensions", "Extensions", "plug", ""),
    ("modules", "Modules", "grid", ""),
    ("task-manager", "Task manager", "activity", "shift+esc"),
    ("clear-data", "Clear browsing data", "trash", "shift+cmd+delete"),
    ("tab-search", "Search tabs", "search", "shift+cmd+a"),
    ("sidebar", "Show or hide sidebar", "sidebar", "cmd+b"),
    ("focus", "Focus mode", "focus", ""),
    ("zoom-in", "Zoom in", "plus", "cmd+="),
    ("zoom-out", "Zoom out", "minus", "cmd+-"),
    ("zoom-reset", "Actual size", "search", "cmd+0"),
    ("home", "Start page", "home", "shift+cmd+h"),
    ("save-session", "Save tabs as a session", "folder", ""),
    ("break", "Take a break", "pause", ""),
    ("fast-forward", "Fast Forward to the next page", "forward", "alt+cmd+]"),
    ("rewind", "Rewind to the site’s first page", "back", "alt+cmd+["),
    ("panic", "Panic button", "shield", "ctrl+alt+cmd+p"),
    ("summarize", "Summarize page", "spark", ""),
    ("palette", "Command bar", "search", "cmd+k"),
];

pub fn action_label(id: &str) -> &'static str {
    ACTIONS.iter().find(|a| a.0 == id).map(|a| a.1).unwrap_or("")
}

/// Shortcut bindings: defaults, then the person's own additions.
/// A custom binding replaces an action's standard one; "none" removes it.
pub fn shortcuts(s: &Shell) -> Vec<(String, String)> {
    let custom = s.snapshot["preferences"]["shortcuts"].as_object();
    let replaced = |action: &str| custom.is_some_and(|c| c.get(action).and_then(Value::as_str).is_some_and(|b| b == "none" || valid_binding(b)));
    let mut out: Vec<(String, String)> = ACTIONS
        .iter()
        .filter(|a| !a.3.is_empty() && !replaced(a.0))
        .map(|a| (a.3.to_string(), a.0.to_string()))
        .collect();
    for (action, binding) in custom.into_iter().flatten() {
        if let Some(binding) = binding.as_str().filter(|b| valid_binding(b)) {
            if ACTIONS.iter().any(|a| a.0 == action) {
                out.retain(|(b, _)| b != binding);
                out.push((binding.to_string(), action.clone()));
            }
        }
    }
    out.retain(|(_, action)| action_on(s, action));
    out
}

/// "ctrl+alt+shift+cmd+key": at least one modifier unless it is a function key.
pub fn valid_binding(binding: &str) -> bool {
    let parts: Vec<&str> = binding.split('+').collect();
    let Some((key, modifiers)) = parts.split_last() else { return false };
    let order = ["ctrl", "alt", "shift", "cmd"];
    let mut last = None;
    for m in modifiers {
        let Some(i) = order.iter().position(|o| o == m) else { return false };
        if last.is_some_and(|l| i <= l) {
            return false;
        }
        last = Some(i);
    }
    let function = key.len() > 1 && key.starts_with('f') && key[1..].parse::<u8>().is_ok_and(|n| (1..=19).contains(&n));
    let named = ["tab", "esc", "delete", "enter", "space", "up", "down", "left", "right"].contains(key);
    let printable = key.chars().count() == 1 && !key.chars().any(char::is_whitespace);
    binding.len() <= 40 && (function || ((named || printable) && !modifiers.is_empty()))
}

/// The request an action performs.
pub fn action_request(s: &Shell, id: &str) -> Option<Value> {
    let tab = s.active()["id"].clone();
    Some(match id {
        "new-tab" => json!({"op":"newTab"}),
        "new-window" => json!({"op":"newWindow"}),
        "private-window" => json!({"op":"privateWindow"}),
        "reopen-tab" => json!({"op":"reopenTab"}),
        "close-tab" => json!({"op":"closeCurrent"}),
        "next-tab" => json!({"op":"tab-step","value":1}),
        "previous-tab" => json!({"op":"tab-step","value":-1}),
        "duplicate-tab" => json!({"op":"duplicateTab","id":tab}),
        "pin-tab" => json!({"op":"pinTab","id":tab}),
        "mute-tab" => json!({"op":"tab-action","id":tab,"value":"mute"}),
        "sleep-tab" => json!({"op":"tab-action","id":tab,"value":"sleep"}),
        "split" => json!({"op":"menu","value":"split-choose"}),
        "find" => json!({"op":"find-open"}),
        "reader" => json!({"op":"reader"}),
        "print" | "save-pdf" | "save-page" | "view-source" | "dev-tools" | "copy-url" | "share" | "pip" | "panic" | "fast-forward" | "rewind" => {
            json!({"op":"page-command","value":id})
        }
        "break" => json!({"op":"page-command","value":"break"}),
        "capture" => json!({"op":"menu","value":"capture"}),
        "bookmark" => json!({"op":"bookmark"}),
        "reading-add" => json!({"op":"reading","value":"add"}),
        "bookmarks" | "history" | "downloads" => json!({"op":"screen","value":"library","section":id}),
        "reading-list" => json!({"op":"screen","value":"library","section":"reading"}),
        "sessions" => json!({"op":"screen","value":"library","section":"sessions"}),
        "boards" => json!({"op":"screen","value":"library","section":"boards"}),
        "settings" | "extensions" | "modules" => json!({"op":"screen","value":id}),
        "customize" => json!({"op":"screen","value":"editor"}),
        "task-manager" => json!({"op":"screen","value":"settings","section":"performance"}),
        "clear-data" => json!({"op":"menu","value":"clear-data"}),
        "tab-search" => json!({"op":"menu","value":"tab-search"}),
        "sidebar" => json!({"op":"sidebar"}),
        "focus" => json!({"op":"native","action":"toggleFocus"}),
        "zoom-in" => json!({"op":"zoom-step","value":"1"}),
        "zoom-out" => json!({"op":"zoom-step","value":"-1"}),
        "zoom-reset" => json!({"op":"zoom-step","value":"0"}),
        "home" => json!({"op":"home"}),
        "save-session" => json!({"op":"menu","value":"save-session"}),
        "summarize" => json!({"op":"summarize"}),
        "palette" => json!({"op":"palette"}),
        _ => return None,
    })
}

/// Query parameters that only identify a click or a campaign.
pub const TRACKING_PARAMETERS: &[&str] = &[
    "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id", "utm_name",
    "fbclid", "gclid", "gclsrc", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid", "yclid",
    "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id", "wickedid", "twclid",
    "ttclid", "srsltid", "ref_src", "si",
];

/// The address without click and campaign identifiers, when any were removed.
pub fn strip_tracking(address: &str) -> Option<String> {
    if let Some(canonical) = de_amp(address) {
        return Some(strip_tracking(&canonical).unwrap_or(canonical));
    }
    let mut url = Url::parse(address).ok()?;
    if !["http", "https"].contains(&url.scheme()) || url.query().is_none() {
        return None;
    }
    let pairs: Vec<(String, String)> = url.query_pairs().map(|(k, v)| (k.into_owned(), v.into_owned())).collect();
    // "si" is only a tracker on a few share links; keep it everywhere else.
    let share = url.host_str().is_some_and(|h| h.ends_with("youtube.com") || h.ends_with("youtu.be") || h.ends_with("spotify.com"));
    let kept: Vec<&(String, String)> = pairs
        .iter()
        .filter(|(k, _)| !TRACKING_PARAMETERS.contains(&k.to_ascii_lowercase().as_str()) || k == "si" && !share)
        .collect();
    if kept.len() == pairs.len() {
        return None;
    }
    if kept.is_empty() {
        url.set_query(None);
    } else {
        url.query_pairs_mut().clear().extend_pairs(kept.iter().map(|(k, v)| (k.as_str(), v.as_str())));
    }
    Some(url.to_string())
}

/// The publisher's address behind a Google AMP cache link, as Brave's De-AMP does.
fn de_amp(address: &str) -> Option<String> {
    let url = Url::parse(address).ok()?;
    let host = url.host_str()?;
    let path = url.path();
    let rest = if (host == "www.google.com" || host == "google.com") && path.starts_with("/amp/s/") {
        &path["/amp/s/".len()..]
    } else if host.ends_with(".cdn.ampproject.org") {
        path.strip_prefix("/c/s/").or_else(|| path.strip_prefix("/v/s/"))?
    } else {
        return None;
    };
    let target = Url::parse(&format!("https://{rest}")).ok()?;
    let mut target = target;
    if let Some(query) = url.query() {
        target.set_query(Some(query));
    }
    (target.host_str().is_some_and(|h| h.contains('.'))).then(|| target.to_string())
}

/// Filter lists offered in Settings: (id, title, address, what it blocks).
pub const FILTER_LISTS: &[(&str, &str, &str, &str)] = &[
    ("easylist", "EasyList", "https://easylist.to/easylist/easylist.txt", "Ads"),
    ("easyprivacy", "EasyPrivacy", "https://easylist.to/easylist/easyprivacy.txt", "Trackers and analytics"),
    ("peter-lowe", "Peter Lowe’s list", "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=0&mimetype=plaintext", "Ad and tracking servers"),
    ("fanboy-annoyance", "Fanboy’s Annoyance List", "https://secure.fanboy.co.nz/fanboy-annoyance.txt", "Cookie notices, pop-ups and in-page annoyances"),
    ("fanboy-social", "Fanboy’s Social Blocking List", "https://easylist.to/easylist/fanboy-social.txt", "Social media buttons and widgets"),
];

/// Element-hiding rules from filter text, as `example.com,~shop.example.com##.ad`
/// or `##.ad`. Exceptions, scriptlets and procedural selectors are skipped.
pub fn parse_cosmetic(source: &str) -> Vec<String> {
    parse_cosmetic_up_to(source, 5000)
}

pub fn parse_cosmetic_up_to(source: &str, limit: usize) -> Vec<String> {
    const PROCEDURAL: [&str; 9] = [":has-text(", ":-abp-", ":xpath(", ":matches-css", ":upward(", ":remove(", ":style(", ":min-text-length(", ":watch-attr("];
    let mut out: Vec<String> = vec![];
    let mut seen = std::collections::HashSet::new();
    for line in source.lines().take(200_000) {
        let line = line.trim();
        let Some((hosts, selector)) = line.split_once("##") else { continue };
        let selector = selector.trim();
        if line.starts_with('!') || hosts.contains(['#', '@', '$', '?', '/', ' ']) || !cosmetic_selector(selector) || PROCEDURAL.iter().any(|p| selector.contains(p)) {
            continue;
        }
        let hosts: Vec<String> = hosts.split(',').map(|h| h.trim().to_ascii_lowercase()).filter(|h| !h.is_empty()).collect();
        if !hosts.iter().all(|h| h.trim_start_matches('~').bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-' || b == b'*')) {
            continue;
        }
        let rule = format!("{}##{selector}", hosts.join(","));
        if seen.insert(rule.clone()) {
            out.push(rule);
            if out.len() == limit {
                break;
            }
        }
    }
    out
}

fn cosmetic_selector(selector: &str) -> bool {
    !selector.is_empty() && selector.len() <= 300 && !selector.starts_with(['+', '@']) && !selector.contains(['<', '{', '}', '\\']) && !selector.contains("/*")
}

/// The element-hiding selectors from stored rules that apply on a site.
pub fn cosmetic_for<'a>(rules: &'a [Value], site: &str) -> Vec<&'a str> {
    let (mut specific, mut generic) = (0, 0);
    let matches = |host: &str| !host.is_empty() && (site == host || site.ends_with(&format!(".{host}")));
    rules
        .iter()
        .filter_map(Value::as_str)
        .filter_map(|rule| rule.split_once("##"))
        .filter(|(hosts, selector)| {
            let hosts: Vec<&str> = hosts.split(',').filter(|h| !h.is_empty()).collect();
            let excluded = hosts.iter().filter_map(|h| h.strip_prefix('~')).any(matches);
            let included: Vec<&&str> = hosts.iter().filter(|h| !h.starts_with('~')).collect();
            if !cosmetic_selector(selector) || excluded {
                return false;
            }
            // Generic rules apply everywhere, so keep their share of each page's stylesheet bounded.
            if included.is_empty() {
                generic += 1;
                generic <= 4000
            } else if included.iter().any(|h| matches(h)) {
                specific += 1;
                specific <= 2000
            } else {
                false
            }
        })
        .map(|(_, selector)| selector)
        .collect()
}

/// Domains from pasted or imported filter text: plain domains, hosts-file lines
/// and network rules of the form `||example.com^`. Other rule types are skipped.
pub fn parse_rules(source: &str) -> Vec<String> {
    parse_rules_up_to(source, 5000)
}

/// The UTC year and month of a time in seconds since 2001-01-01.
fn year_month(seconds: f64) -> (u32, u32) {
    // Days since 0000-03-01, from Howard Hinnant's civil_from_days.
    let z = (seconds / 86_400.).floor().clamp(-1e6, 1e6) as i32 as i64 + 11_323 + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    ((yoe + era * 400 + i64::from(month <= 2)) as u32, month as u32)
}
/// Whether a card number passes the Luhn check card issuers use.
fn luhn(number: &str) -> bool {
    let digits: Vec<u32> = number.chars().filter_map(|c| c.to_digit(10)).collect();
    (12..=19).contains(&digits.len())
        && digits.iter().rev().enumerate().map(|(i, d)| if i % 2 == 1 { let x = d * 2; if x > 9 { x - 9 } else { x } } else { *d }).sum::<u32>() % 10 == 0
}

/// A host name with at least two labels and a letter-only top-level domain.
fn hostname(domain: &str) -> bool {
    let labels: Vec<&str> = domain.split('.').collect();
    domain.len() <= 253
        && labels.len() >= 2
        && labels.iter().all(|l| !l.is_empty() && l.len() <= 63 && !l.starts_with('-') && !l.ends_with('-') && l.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-'))
        && labels.last().is_some_and(|tld| tld.len() >= 2 && tld.bytes().all(|b| b.is_ascii_alphabetic()))
}

/// Options a domain rule may carry and still block the whole domain's
/// third-party requests, which is how Neutrino applies every rule.
const DOMAIN_RULE_OPTIONS: [&str; 5] = ["third-party", "3p", "all", "important", "document"];

/// Options an address rule may carry. Resource types only narrow a rule, so
/// applying it to every subresource is broader but never misses; others are skipped.
const PATTERN_OPTIONS: [&str; 18] = ["third-party", "3p", "script", "image", "stylesheet", "css", "subdocument", "frame",
    "xmlhttprequest", "xhr", "media", "object", "ping", "other", "font", "websocket", "important", "all"];

/// Address rules anchored to a host, such as `||example.com/ads/*` or `||cdn.example^*banner`,
/// as `||host<rest>` with `$third-party` when the rule says so. Hosts the list exempts
/// with an `@@` rule are left out, since their exceptions aren't applied.
pub fn parse_patterns_up_to(source: &str, limit: usize) -> Vec<String> {
    let host_end = |rule: &str| rule.find(['^', '/', '*', '?', ':', '$', '|']).unwrap_or(rule.len());
    let exempt: std::collections::HashSet<String> = source.lines().take(400_000)
        .filter_map(|l| l.trim().strip_prefix("@@||").map(|r| r[..host_end(r)].to_ascii_lowercase())).collect();
    let mut out = vec![];
    let mut seen = std::collections::HashSet::new();
    for line in source.lines().take(400_000) {
        let Some(rule) = line.trim().strip_prefix("||") else { continue };
        let (pattern, options) = rule.split_once('$').unwrap_or((rule, ""));
        if !options.is_empty() && !options.split(',').all(|o| PATTERN_OPTIONS.contains(&o)) {
            continue;
        }
        let third = options.split(',').any(|o| o == "third-party" || o == "3p");
        let pattern = pattern.to_ascii_lowercase();
        let (host, rest) = pattern.split_at(host_end(&pattern));
        let body = rest.strip_suffix('|').unwrap_or(rest);
        // A rule that is only its host is a domain rule; ports and regular expressions are left out.
        if body.trim_end_matches(['^', '*']).is_empty() || !hostname(host) || exempt.contains(host) || rest.starts_with(':') {
            continue;
        }
        if body.len() > 200 || body.matches('*').count() > 3 || !body.bytes().all(|b| b.is_ascii_alphanumeric() || b"/._-*^?=&%~,;".contains(&b)) {
            continue;
        }
        let rule = format!("||{host}{rest}{}", if third { "$third-party" } else { "" });
        if seen.insert(rule.clone()) {
            out.push(rule);
            if out.len() >= limit {
                break;
            }
        }
    }
    out
}

/// A WebKit `url-filter` for an address rule from `parse_patterns_up_to`, and whether
/// it applies only to third-party requests.
pub fn pattern_url_filter(rule: &str) -> Option<(String, bool)> {
    let (pattern, options) = rule.split_once('$').unwrap_or((rule, ""));
    let rest = pattern.strip_prefix("||")?;
    let end = rest.find(['^', '/', '*', '?'])?;
    let (host, tail) = rest.split_at(end);
    if !hostname(host) {
        return None;
    }
    let (tail, anchored) = tail.strip_suffix('|').map_or((tail, false), |t| (t, true));
    let mut filter = format!(r"^[a-z]+://([^/]+\.)?{}", host.replace('.', r"\."));
    let chars: Vec<char> = tail.chars().collect();
    for (i, c) in chars.iter().enumerate() {
        match c {
            '*' => filter.push_str(".*"),
            // A separator; at the end it may also be the end of the address, which WebKit can't say, so it is left out.
            '^' => if i + 1 < chars.len() { filter.push_str("[/:?&=]") },
            '.' | '?' => { filter.push('\\'); filter.push(*c) }
            c if c.is_ascii_alphanumeric() || "/_-=&%~,;".contains(*c) => filter.push(*c),
            _ => return None,
        }
    }
    if anchored {
        filter.push('$');
    }
    Some((filter, options == "third-party"))
}

/// Domain rules from a subscribed filter list, which may hold tens of thousands.
pub fn parse_rules_up_to(source: &str, limit: usize) -> Vec<String> {
    let mut out = vec![];
    let mut seen = std::collections::HashSet::new();
    // In Adblock-style lists a bare line is a URL pattern, not a domain.
    let adblock = source.lines().take(40).any(|l| l.starts_with("[Adblock") || l.starts_with("! Title:"))
        || source.lines().take(4000).filter(|l| l.starts_with("||")).count() >= 20;
    for line in source.lines().take(400_000) {
        let line = line.trim();
        if line.is_empty() || line.starts_with('!') || line.starts_with('#') || line.starts_with('[') || line.contains("##") || line.starts_with("@@") {
            continue;
        }
        let candidate = if let Some(rule) = line.strip_prefix("||") {
            let end = rule.find(['^', '/', '$']).unwrap_or(rule.len());
            let (pattern, options) = rule[end..].split_once('$').unwrap_or((&rule[end..], ""));
            if pattern.trim_start_matches('^').contains('/') || !pattern.trim_start_matches('^').is_empty()
                || !options.is_empty() && !options.split(',').all(|o| DOMAIN_RULE_OPTIONS.contains(&o))
            {
                continue;
            }
            &rule[..end]
        } else if let Some(rest) = line.strip_prefix("0.0.0.0 ").or_else(|| line.strip_prefix("127.0.0.1 ")) {
            rest.split_whitespace().next().unwrap_or("")
        } else if !adblock && !line.contains(' ') && !line.contains('/') {
            line
        } else {
            continue;
        };
        let domain = candidate.trim_start_matches("*.").trim_end_matches('.').to_ascii_lowercase();
        if hostname(&domain)
            && !["localhost", "local", "0.0.0.0"].contains(&domain.as_str())
            && seen.insert(domain.clone())
        {
            out.push(domain);
            if out.len() == limit {
                break;
            }
        }
    }
    out
}

/// A web address the person typed into one of the forms, if it is usable.
fn web_address(input: &str) -> Option<String> {
    let input = input.trim();
    let candidate = if input.contains("://") { input.to_string() } else { format!("https://{input}") };
    let url = Url::parse(&candidate).ok()?;
    (["http", "https"].contains(&url.scheme()) && url.host_str().is_some_and(|h| h.contains('.') || h == "localhost") && url.username().is_empty())
        .then(|| url.to_string())
}

/// Search engines: built-in ones, then the person's own.
pub fn search_engines(s: &Shell) -> Vec<(String, String, String, String)> {
    let mut out: Vec<(String, String, String, String)> = [
        ("duckDuckGo", "DuckDuckGo", "d", "https://duckduckgo.com/?q=%s"),
        ("google", "Google", "g", "https://www.google.com/search?q=%s"),
        ("bing", "Bing", "b", "https://www.bing.com/search?q=%s"),
        ("wikipedia", "Wikipedia", "w", "https://en.wikipedia.org/w/index.php?search=%s"),
        ("brave", "Brave Search", "br", "https://search.brave.com/search?q=%s"),
        ("startpage", "Startpage", "sp", "https://www.startpage.com/do/search?q=%s"),
        ("ecosia", "Ecosia", "e", "https://www.ecosia.org/search?q=%s"),
        ("youtube", "YouTube", "yt", "https://www.youtube.com/results?search_query=%s"),
    ]
    .iter()
    .map(|(a, b, c, d)| (a.to_string(), b.to_string(), c.to_string(), d.to_string()))
    .collect();
    for e in array(&s.snapshot["preferences"]["searchEngines"]) {
        out.push((text(e, "id").into(), text(e, "name").into(), text(e, "keyword").into(), text(e, "url").into()));
    }
    out
}

/// Typed text to an address: "keyword terms" uses that engine; otherwise the default.
pub fn resolve(s: &Shell, input: &str) -> Option<String> {
    let engines = search_engines(s);
    let input = input.trim();
    if let Some((keyword, terms)) = input.split_once(' ') {
        if let Some(engine) = engines.iter().find(|e| !e.2.is_empty() && e.2.eq_ignore_ascii_case(keyword)) {
            if !terms.trim().is_empty() {
                return Some(engine.3.replace("%s", &urlencode(terms.trim())));
            }
        }
    }
    let default = text(&s.snapshot["preferences"], "defaultSearchID");
    let resolved = if let Some(engine) = engines.iter().skip(3).find(|e| e.0 == default) {
        resolve_address(input, "duckDuckGo").map(|address| {
            if address.starts_with("https://duckduckgo.com/?q=") && !input.contains("duckduckgo.com") {
                engine.3.replace("%s", &urlencode(input))
            } else {
                address
            }
        })
    } else {
        resolve_address(input, text(&s.snapshot["preferences"], "search"))
    }?;
    Some(if s.snapshot["preferences"]["stripTracking"].as_bool().unwrap_or(true) {
        strip_tracking(&resolved).unwrap_or(resolved)
    } else {
        resolved
    })
}

fn urlencode(value: &str) -> String {
    url::form_urlencoded::byte_serialize(value.as_bytes()).collect::<String>().replace('+', "%20")
}

/// Visible tabs in strip order, for ⌘1–9 and keyboard cycling.
fn ordered_tabs(s: &Shell) -> Vec<Value> {
    s.tabs()
        .iter()
        .filter(|t| crate::render::tab_visible(t, s) || t["id"] == s.active()["id"])
        .cloned()
        .collect()
}

fn site_of_active(s: &Shell) -> Option<String> {
    let url = text(s.active(), "url");
    (!url.is_empty()).then(|| host(url))
}

/// Preference keys set with the generic "setting" request, with their validation.
fn valid_setting(key: &str, v: &Value) -> bool {
    let int = |min: i64, max: i64| v.as_i64().is_some_and(|n| (min..=max).contains(&n));
    match key {
        "sleepAfterMinutes" => [0, 15, 30, 60, 120, 240].contains(&v.as_i64().unwrap_or(-1)),
        "memoryLimitMB" => [0, 1024, 2048, 4096, 8192].contains(&v.as_i64().unwrap_or(-1)),
        "cpuLimit" => [0, 25, 50, 75].contains(&v.as_i64().unwrap_or(-1)),
        "networkLimitKBps" => [0, 256, 1024, 5120, 10240].contains(&v.as_i64().unwrap_or(-1)),
        "autoArchiveDays" => [0, 1, 7, 14, 30].contains(&v.as_i64().unwrap_or(-1)),
        "batterySaver" | "hideCookieBanners" | "blockThirdPartyCookies" | "httpsUpgrade" | "stripTracking" | "hideLocalIP"
        | "littleArc" | "peek" | "tabIslands" | "keyboardSounds" | "backgroundMusic" | "askWhereToSave" | "mouseGestures"
        | "interfaceSounds" | "clearHistoryOnQuit" | "clearCookiesOnQuit" | "clearCacheOnQuit"
        | "blockCamera" | "blockMicrophone" | "blockLocation" | "blockNotifications" => v.is_boolean(),
        "musicVolume" => v.as_f64().is_some_and(|n| (0.0..=1.0).contains(&n)),
        "defaultSearchID" => v.as_str().is_some_and(|id| id.len() <= 64),
        "interfaceCSS" => v.as_str().is_some_and(|css| css.len() <= 65_536 && !css.contains('<')),
        "startupPages" => v.as_array().is_some_and(|pages| pages.len() <= 20 && pages.iter().all(|p| p.as_str().and_then(web_address).is_some())),
        "startupMode" => ["restore", "start", "pages"].contains(&v.as_str().unwrap_or("")),
        "startPage" => v.as_object().is_some_and(|o| o.len() <= 6 && o.iter().all(|(k, v)| ["clock", "sites", "search", "stats", "wallpaper", "reading"].contains(&k.as_str()) && v.is_boolean())),
        "themeSchedule" => v.as_object().is_some_and(|o| {
            let time = |k: &str| o.get(k).and_then(Value::as_str).is_some_and(|t| t.len() == 5 && t.as_bytes()[2] == b':' && t[..2].parse::<u8>().is_ok_and(|h| h < 24) && t[3..].parse::<u8>().is_ok_and(|m| m < 60));
            o.get("enabled").is_some_and(Value::is_boolean) && time("light") && time("dark")
        }),
        "readerStyle" => v.as_object().is_some_and(|o| {
            o.get("size").and_then(Value::as_i64).is_some_and(|n| (14..=28).contains(&n))
                && ["light", "sepia", "dark", "auto"].contains(&o.get("theme").and_then(Value::as_str).unwrap_or(""))
                && ["serif", "sans"].contains(&o.get("font").and_then(Value::as_str).unwrap_or(""))
        }),
        "downloadFolder" => v.is_null(),
        "liveWallpaper" => ["", "aurora", "waves", "embers"].contains(&v.as_str().unwrap_or("-")),
        _ => int(i64::MIN, i64::MIN),
    }
}

pub fn dispatch(s: &mut Shell, op: &str, r: &Value, commands: &mut Vec<Value>) {
    let id = r["id"].clone();
    let value = text(r, "value");
    let tab = s.tabs().iter().find(|t| t["id"] == id).cloned();
    let regular = !s.private();
    let module = match op {
        "reading" => "reading-list",
        "session" => "sessions",
        "board" | "board-select" => "boards",
        "web-panel" => "web-panels",
        "favorite" => "favorites",
        "boost" => "boosts",
        "chain" => "command-chains",
        "link-route" => "link-routes",
        "tidy-tabs" => "tidy-tabs",
        "address-book" | "card" => "autofill",
        "feed" => "feeds",
        "browser-passwords" => "password-manager",
        "fake-history" => "fake-history",
        "page-command" if value == "panic" => "panic",
        "page-command" if value == "break" => "break-mode",
        "page-command" if value == "fast-forward" || value == "rewind" => "fast-forward",
        "tab-action" if value == "sleep" => "tab-sleep",
        "tab-action" if value == "favorite" => "favorites",
        "site-setting" if text(r, "key") == "filter" => "page-styles",
        "site-setting" if text(r, "key") == "forget" => "forget-sites",
        _ => "",
    };
    if !module.is_empty() && !on(s, module) {
        s.notice = "That feature is off. Turn it on in Modules.".into();
        return;
    }
    match op {
        "tab-action" => {
            let Some(t) = tab else { return };
            let url = text(&t, "url").to_string();
            match value {
                "reload" if !url.is_empty() => commands.push(json!({"op":"reloadTab","id":id})),
                "mute" => commands.push(json!({"op":"muteTab","id":id,"value":!flag(&t,"muted")})),
                "copy" if !url.is_empty() => {
                    commands.push(json!({"op":"copyText","value":url}));
                    s.notice = "Link copied.".into();
                }
                "bookmark" if !url.is_empty() && regular => commands.push(json!({"op":"addBookmark","url":url,"title":t["title"]})),
                "sleep" if !url.is_empty() && id != s.active()["id"] => commands.push(json!({"op":"sleepTab","id":id})),
                "new-right" => commands.push(json!({"op":"newTabAfter","id":id})),
                "close-others" | "close-right" => {
                    let others: Vec<Value> = if value == "close-others" {
                        s.tabs().iter().filter(|x| x["id"] != id && !flag(x, "pinned")).map(|x| x["id"].clone()).collect()
                    } else {
                        let at = s.tabs().iter().position(|x| x["id"] == id).unwrap_or(0);
                        s.tabs().iter().skip(at + 1).filter(|x| !flag(x, "pinned")).map(|x| x["id"].clone()).collect()
                    };
                    if !others.is_empty() {
                        commands.push(json!({"op":"closeTabs","ids":others}));
                    }
                }
                "reset-pinned" if !text(&t, "pinnedURL").is_empty() => commands.push(json!({"op":"resetPinnedTab","id":id})),
                "favorite" if !url.is_empty() && regular => commands.push(json!({"op":"addFavorite","id":id})),
                "split" if !url.is_empty() && id != s.active()["id"] => commands.push(json!({"op":"splitWith","id":id})),
                "new-window" if regular && s.tabs().len() > 1 => commands.push(json!({"op":"tabToNewWindow","id":id})),
                "rename" => {
                    s.menu = format!("rename-tab:{}", text(&t, "id"));
                    s.name = text(&t, "customTitle").to_string();
                    return;
                }
                _ => return,
            }
            s.menu.clear();
        }
        "rename-tab" => {
            if tab.is_some() {
                commands.push(json!({"op":"renameTab","id":id,"name":bound(&s.name, 120)}));
                s.menu.clear();
                s.name.clear();
            }
        }
        "select-index" => {
            let tabs = ordered_tabs(s);
            let n = r["value"].as_u64().unwrap_or(0) as usize;
            let target = if n == 9 { tabs.last() } else if n >= 1 { tabs.get(n - 1) } else { None };
            if let Some(t) = target {
                commands.push(json!({"op":"selectTab","id":t["id"]}));
                s.palette = false;
            }
        }
        "tab-step" => {
            let step = r["value"].as_i64().unwrap_or(1).signum();
            // Opera and Vivaldi cycle in the order tabs were last used.
            let mut tabs = ordered_tabs(s);
            if ["gx", "vivaldi"].contains(&crate::render::style(s)) && tabs.iter().all(|t| t["lastUsedAt"].is_number()) {
                tabs.sort_by(|a, b| b["lastUsedAt"].as_f64().unwrap_or(0.).total_cmp(&a["lastUsedAt"].as_f64().unwrap_or(0.)));
            }
            if let Some(i) = tabs.iter().position(|t| t["id"] == s.active()["id"]) {
                if tabs.len() > 1 {
                    let next = (i as i64 + step).rem_euclid(tabs.len() as i64) as usize;
                    commands.push(json!({"op":"selectTab","id":tabs[next]["id"]}));
                }
            }
        }
        "reopen-closed" => {
            let index = r["index"].as_u64().unwrap_or(0) as usize;
            if index < array(&s.snapshot["closedTabs"]).len() {
                commands.push(json!({"op":"reopenClosed","index":index}));
                s.menu.clear();
            }
        }
        "find-open" => {
            if !text(s.active(), "url").is_empty() {
                s.find_open = true;
                s.focus = "find-input".into();
                s.menu.clear();
                if !s.find_query.is_empty() {
                    commands.push(json!({"op":"findCount","value":s.find_query}));
                }
            }
        }
        "find-query" => {
            s.find_query = bound(value, 1024);
            s.find_index = usize::from(!s.find_query.is_empty());
            commands.push(json!({"op":"find","value":s.find_query,"backwards":false}));
            commands.push(json!({"op":"findCount","value":s.find_query}));
        }
        "find-step" => {
            if !s.find_query.is_empty() {
                let back = r["value"].as_i64().unwrap_or(1) < 0;
                let count = s.snapshot["findResult"]["count"].as_u64().unwrap_or(0) as usize;
                if count > 0 {
                    s.find_index = if back { if s.find_index <= 1 { count } else { s.find_index - 1 } } else if s.find_index >= count { 1 } else { s.find_index + 1 };
                }
                commands.push(json!({"op":"find","value":s.find_query,"backwards":back}));
            }
        }
        "find-close" => {
            s.find_open = false;
            commands.push(json!({"op":"find","value":"","backwards":false}));
        }
        "address-input" => {
            s.address_query = bound(value, 2048);
            s.suggest_index = 0;
            if s.address_query.is_empty() {
                if s.menu == "suggest" {
                    s.menu.clear();
                }
            } else {
                s.menu = "suggest".into();
                commands.push(json!({"op":"suggest","value":s.address_query}));
            }
        }
        "suggest-move" => {
            let count = suggestions(s).len();
            if count > 0 {
                let step = r["value"].as_i64().unwrap_or(1);
                s.suggest_index = ((s.suggest_index as i64 + step).rem_euclid(count as i64 + 1)) as usize;
            }
        }
        "suggest-accept" => {
            let list = suggestions(s);
            let choice = r["index"].as_u64().map(|i| i as usize + 1).unwrap_or(s.suggest_index);
            if let Some(item) = choice.checked_sub(1).and_then(|i| list.get(i)) {
                if text(item, "kind") == "tab" {
                    commands.push(json!({"op":"selectTab","id":item["id"]}));
                } else if let Some(url) = resolve(s, text(item, "url")) {
                    commands.push(json!({"op":"navigate","url":url}));
                }
            } else if let Some(url) = resolve(s, &s.address_query.clone()) {
                commands.push(json!({"op":"navigate","url":url}));
            }
            s.menu.clear();
            s.address_query.clear();
            s.suggest_index = 0;
        }
        "page-command" => {
            let blank = text(s.active(), "url").is_empty();
            let page_only = ["print", "save-pdf", "save-page", "view-source", "dev-tools", "copy-url", "share", "pip", "pick-element", "fast-forward", "rewind"];
            if page_only.contains(&value) && blank {
                s.notice = "Open a page first.".into();
                return;
            }
            let command = match value {
                "print" => "print",
                "save-pdf" => "savePDF",
                "save-page" => "savePage",
                "view-source" => {
                    s.screen = "source".into();
                    "viewSource"
                }
                "dev-tools" => "devTools",
                "copy-url" => {
                    s.notice = "Address copied.".into();
                    commands.push(json!({"op":"copyText","value":text(s.active(),"url")}));
                    s.menu.clear();
                    return;
                }
                "share" => "share",
                "pip" => "pip",
                "pick-element" if !regular => return,
                "pick-element" => "pickElement",
                "fast-forward" => "fastForward",
                "rewind" => "rewind",
                "media" => "mediaToggle",
                "break" => "breakMode",
                "panic" => "panic",
                _ => return,
            };
            commands.push(json!({"op":command,"id":if id.is_null() {s.active()["id"].clone()} else {id}}));
            s.menu.clear();
        }
        "nav-history" => {
            if ["back", "forward"].contains(&value) && !text(s.active(), "url").is_empty() {
                s.menu = format!("nav-history:{value}");
                commands.push(json!({"op":"navigationList","direction":value}));
            }
        }
        "go-history" => {
            if let Some(offset) = r["offset"].as_i64().filter(|o| *o != 0 && o.abs() <= 50) {
                commands.push(json!({"op":"goToHistory","offset":offset}));
                s.menu.clear();
            }
        }
        "site-setting" => {
            let key = text(r, "key");
            // Settings → Privacy edits a listed site; the site menu edits the current page's site.
            let listed = |host: &str| s.snapshot["preferences"]["siteSettings"].get(host).is_some() || s.snapshot["preferences"]["siteZoom"].get(host).is_some();
            let requested = text(r, "host");
            let site = if !requested.is_empty() { listed(requested).then(|| requested.to_string()) } else { site_of_active(s) };
            let Some(site) = site else { return };
            let valid = match key {
                "blockScripts" | "allowPopups" | "muted" | "forget" => r["value"].is_boolean(),
                "camera" | "microphone" => ["ask", "allow", "block"].contains(&value),
                "filter" => ["", "dark", "grayscale", "sepia", "invert", "contrast", "noimages"].contains(&value),
                "hide" => value.is_empty(),
                _ => false,
            };
            if valid && regular {
                commands.push(json!({"op":"siteSetting","host":site,"key":key,"value":r["value"]}));
            }
        }
        "clear-data" => {
            let range = text(r, "range");
            let items = |k: &str| array(&r["items"]).iter().any(|v| v == k);
            if ["hour", "day", "week", "month", "all"].contains(&range) && ["history", "cookies", "cache", "downloads"].iter().any(|k| items(k)) {
                commands.push(json!({"op":"clearBrowsingData","range":range,"history":items("history"),"cookies":items("cookies"),"cache":items("cache"),"downloads":items("downloads")}));
                s.menu.clear();
                s.notice = "Browsing data cleared.".into();
            } else {
                s.notice = "Choose what to clear.".into();
            }
        }
        "site-data" => match value {
            "load" => commands.push(json!({"op":"loadSiteData"})),
            "remove" if text(r, "host").len() <= 253 && !text(r, "host").is_empty() => commands.push(json!({"op":"clearSiteData","host":text(r,"host")})),
            _ => {}
        },
        "edit-bookmark" => {
            let title = bound(text(r, "title"), 512);
            let folder = bound(text(r, "folder"), 80);
            match web_address(text(r, "url")) {
                Some(url) if regular && array(&s.snapshot["bookmarkIndex"]).iter().any(|b| b["id"] == id) => {
                    commands.push(json!({"op":"editBookmark","id":id,"title":if title.is_empty() {host(&url)} else {title},"url":url,"folder":folder}));
                    s.menu.clear();
                }
                _ => s.notice = "Enter a website address, like example.com.".into(),
            }
        }
        "reading" => match value {
            "add" | "playlist" if regular => {
                let t = s.active().clone();
                if !text(&t, "url").is_empty() {
                    commands.push(json!({"op":"addReadingItem","url":t["url"],"title":t["title"],"media":value=="playlist"}));
                    s.notice = if value == "playlist" { "Added to Playlist." } else { "Added to Reading List." }.into();
                    s.menu.clear();
                }
            }
            "read" | "unread" | "remove" if array(&s.snapshot["preferences"]["readingList"]).iter().any(|i| i["id"] == id) => {
                commands.push(json!({"op":"readingItem","id":id,"value":value}));
            }
            // Brave's Playlist plays its items one after another in one tab.
            "play-all" if regular => commands.push(json!({"op":"playlist","value":"start"})),
            "play-next" | "play-stop" if s.snapshot["playlist"].is_object() => commands.push(json!({"op":"playlist","value":if value == "play-next" {"next"} else {"stop"}})),
            _ => {}
        },
        "session" => match value {
            "save" if regular && !s.name.trim().is_empty() => {
                commands.push(json!({"op":"saveSession","name":bound(&s.name,80)}));
                s.menu.clear();
                s.name.clear();
                s.notice = "Session saved. Open it from Library → Sessions.".into();
            }
            "open" | "delete" if array(&s.snapshot["preferences"]["savedSessions"]).iter().any(|v| v["id"] == id) => {
                commands.push(json!({"op":if value=="open"{"openSession"}else{"deleteSession"},"id":id}));
                s.menu.clear();
                if value == "open" {
                    s.screen = "browse".into();
                }
            }
            _ => {}
        },
        "board" => {
            let board = text(r, "board");
            let boards = array(&s.snapshot["preferences"]["boards"]);
            let exists = boards.iter().any(|b| text(b, "id") == board);
            match value {
                "create" if regular && !s.name.trim().is_empty() => {
                    commands.push(json!({"op":"createBoard","name":bound(&s.name,80)}));
                    s.menu.clear();
                    s.name.clear();
                }
                "delete" if exists => {
                    commands.push(json!({"op":"deleteBoard","id":board}));
                    s.board.clear();
                    s.menu.clear();
                }
                "add-page" if exists && !text(s.active(), "url").is_empty() => {
                    commands.push(json!({"op":"boardAdd","board":board,"kind":"link","title":s.active()["title"],"url":s.active()["url"],"text":""}));
                    s.menu.clear();
                }
                "add-note" if exists && !s.name.trim().is_empty() => {
                    commands.push(json!({"op":"boardAdd","board":board,"kind":"note","title":"","url":"","text":bound(&s.name,2000)}));
                    s.name.clear();
                    s.menu.clear();
                }
                "move" if exists => {
                    let x = r["x"].as_f64().unwrap_or(0.).clamp(0., 4000.);
                    let y = r["y"].as_f64().unwrap_or(0.).clamp(0., 4000.);
                    commands.push(json!({"op":"boardMove","board":board,"item":text(r,"item"),"x":x.round(),"y":y.round()}));
                }
                "remove" if exists => commands.push(json!({"op":"boardRemove","board":board,"item":text(r,"item")})),
                // A picture of the current page, as Arc's Easels and Opera's Pinboards hold.
                "add-capture" if exists && regular && !text(s.active(), "url").is_empty() => commands.push(json!({"op":"boardCapture","board":board})),
                _ => {}
            }
        }
        "board-select" => s.board = bound(value, 64),
        "web-panel" => match value {
            "add" => match web_address(&s.name) {
                Some(url) if regular => {
                    let title = text(r, "title");
                    commands.push(json!({"op":"addWebPanel","url":url,"title":if title.is_empty() {host(&url)} else {bound(title,80)}}));
                    s.menu.clear();
                    s.name.clear();
                }
                _ => s.notice = "Enter a website address, like web.whatsapp.com.".into(),
            },
            "preset" => {
                if let Some((title, url)) = WEB_PANEL_SITES.iter().find(|p| p.1 == text(r, "url")) {
                    commands.push(json!({"op":"addWebPanel","url":url,"title":title}));
                    s.menu.clear();
                }
            }
            "remove" | "reload" | "tab" if array(&s.snapshot["preferences"]["webPanels"]).iter().any(|p| p["id"] == id) => {
                commands.push(json!({"op":match value {"remove"=>"removeWebPanel","reload"=>"reloadWebPanel",_=>"webPanelAsTab"},"id":id}));
                if value == "remove" && s.panel == format!("web:{}", id.as_str().unwrap_or("")) {
                    s.panel = "closed".into();
                }
                s.menu.clear();
            }
            _ => {}
        },
        "favorite" => match value {
            "open" | "remove" if array(&s.snapshot["preferences"]["favorites"]).iter().any(|f| f["id"] == id) => {
                commands.push(json!({"op":if value=="open"{"openFavorite"}else{"removeFavorite"},"id":id}));
                s.menu.clear();
            }
            _ => {}
        },
        "space-appearance" => {
            let target = text(&s.snapshot["session"], "spaceID").to_string();
            let emoji = bound(text(r, "emoji"), 8);
            let gradient: Vec<&str> = array(&r["gradient"]).iter().filter_map(Value::as_str).filter(|h| crate::appearance::hex(h)).take(2).collect();
            if regular && (emoji.chars().count() <= 2) {
                commands.push(json!({"op":"setSpaceAppearance","id":target,"emoji":emoji,"gradient":gradient}));
            }
        }
        // Reads the Reader text aloud with the system voice.
        "reader-speak" => {
            if value == "stop" {
                commands.push(json!({"op":"readerSpeak","value":"stop"}));
            } else if s.screen == "reader" && !text(&s.snapshot, "assistantResponse").is_empty() {
                commands.push(json!({"op":"readerSpeak","value":"start"}));
            }
        }
        // Opera GX's Fake My History: ordinary visits of one kind, dated over the last day by the host.
        "fake-history" => {
            if let Some((_, _, sites)) = FAKE_HISTORY.iter().find(|c| c.0 == value) {
                if regular {
                    commands.push(json!({"op":"fakeHistory","entries":sites.iter().map(|(title, url)| json!({"title":title,"url":url})).collect::<Vec<_>>()}));
                }
            }
        }
        // Saved passwords from a Chromium-family browser, decrypted by the host with that browser's Keychain key.
        "browser-passwords" => {
            if regular && crate::onboarding::PASSWORD_SOURCES.contains(&value) {
                commands.push(json!({"op":"importBrowserPasswords","value":value}));
                s.notice = "macOS may ask to let Neutrino use the browser’s password key.".into();
            }
        }
        "nest-folder" => {
            let (id, parent) = (text(r, "id"), text(r, "parent"));
            let folders = array(&s.snapshot["folders"]);
            let exists = |f: &str| folders.iter().any(|v| text(v, "id") == f);
            let fits = parent.is_empty() || (exists(parent) && !crate::render::folder_within(s, parent, id) && crate::render::folder_depth(s, parent) + crate::render::folder_height(s, id) <= crate::render::MAX_FOLDER_DEPTH);
            if regular && exists(id) && fits {
                commands.push(json!({"op":"nestFolder","id":id,"parent":parent}));
                s.menu.clear();
            } else if regular && exists(id) && id != parent {
                s.notice = format!("Folders go up to {} levels deep, and a folder can’t go inside one of its own folders.", crate::render::MAX_FOLDER_DEPTH + 1);
            }
        }
        "folder-color" => {
            if array(&s.snapshot["folders"]).iter().any(|f| f["id"] == id) && FOLDER_COLORS.iter().any(|c| c.0 == value) {
                commands.push(json!({"op":"folderColor","id":id,"value":value}));
                s.menu.clear();
            }
        }
        "delete-space" => {
            let spaces = array(&s.snapshot["spaces"]).iter().filter(|v| v["profileID"] == s.snapshot["session"]["profileID"]).count();
            if regular && spaces > 1 && array(&s.snapshot["spaces"]).iter().any(|v| v["id"] == id) {
                commands.push(json!({"op":"deleteSpace","id":id}));
                s.menu.clear();
            } else if spaces <= 1 {
                s.notice = "A Profile keeps at least one Space.".into();
            }
        }
        "delete-profile" => {
            if regular && array(&s.snapshot["profiles"]).len() > 1 && array(&s.snapshot["profiles"]).iter().any(|p| p["id"] == id) {
                commands.push(json!({"op":"deleteProfile","id":id}));
                s.menu.clear();
            }
        }
        "capture-mode" => {
            if text(s.active(), "url").is_empty() {
                return;
            }
            match value {
                "visible" | "copy" | "full" | "markup" => {
                    commands.push(json!({"op":"captureImage","mode":value}));
                    s.menu.clear();
                }
                "area" | "area-markup" => {
                    s.capture_select = true;
                    s.capture_markup = value == "area-markup";
                    s.menu.clear();
                }
                "cancel" => s.capture_select = false,
                _ => {}
            }
        }
        "capture-area" => {
            let n = |k: &str| r[k].as_f64().filter(|v| v.is_finite() && *v >= 0. && *v <= 20_000.);
            if let (Some(x), Some(y), Some(w), Some(h)) = (n("x"), n("y"), n("width"), n("height")) {
                if w >= 4. && h >= 4. {
                    commands.push(json!({"op":"captureArea","x":x,"y":y,"width":w,"height":h,"copy":flag(r,"copy"),"markup":s.capture_markup}));
                }
            }
            s.capture_select = false;
            s.capture_markup = false;
        }
        // The markup editor: the interface draws on the capture and sends back a PNG.
        "markup" => match value {
            "save" | "copy" => {
                let data = text(r, "data");
                if data.starts_with("data:image/png;base64,") && data.len() <= 40 * 1024 * 1024 {
                    commands.push(json!({"op":"markupSave","data":data,"copy":value == "copy"}));
                }
            }
            "cancel" => commands.push(json!({"op":"markupClose"})),
            _ => {}
        },
        "split-axis" => {
            if ["sideBySide", "stacked", "grid"].contains(&value) {
                commands.push(json!({"op":"splitAxis","value":value}));
                s.menu.clear();
            }
        }
        "custom-rules" => match value {
            "import" => commands.push(json!({"op":"importRules"})),
            "clear" => commands.push(json!({"op":"customRules","domains":[],"cosmetic":[]})),
            _ => {
                let domains = parse_rules(text(r, "rules"));
                let cosmetic = parse_cosmetic(text(r, "rules"));
                let plural = |n: usize, one: &str, many: &str| format!("{n} {}", if n == 1 { one } else { many });
                s.notice = match (domains.len(), cosmetic.len()) {
                    (_, 0) => format!("{} blocked from your rules.", plural(domains.len(), "site is", "sites are")),
                    (0, c) => format!("{} saved.", plural(c, "element rule", "element rules")),
                    (d, c) => format!("{} blocked and {} saved.", plural(d, "site", "sites"), plural(c, "element rule", "element rules")),
                };
                commands.push(json!({"op":"customRules","domains":domains,"cosmetic":cosmetic}));
            }
        },
        "search-engine" => match value {
            "save" => {
                let name = bound(text(r, "name"), 60);
                let keyword = bound(text(r, "keyword"), 20).to_lowercase();
                let address = text(r, "url").trim();
                let usable = address.contains("%s") && web_address(&address.replace("%s", "test")).is_some_and(|u| u.starts_with("https://"));
                if !name.is_empty() && usable && !keyword.contains(' ') && !search_engines(s).iter().any(|e| !keyword.is_empty() && e.2 == keyword) {
                    commands.push(json!({"op":"saveSearchEngine","name":name,"keyword":keyword,"url":address}));
                } else {
                    s.notice = "Enter a name, an unused keyword and an HTTPS address containing %s where the search terms go.".into();
                }
            }
            "remove" => commands.push(json!({"op":"removeSearchEngine","id":id})),
            _ => {}
        },
        "address-book" => match value {
            "save" => {
                let fields = ["name", "organization", "street", "city", "region", "postalCode", "country", "email", "phone"];
                let mut entry = json!({});
                for f in fields {
                    entry[f] = json!(bound(text(&r["fields"], f), 200));
                }
                if fields.iter().any(|f| !text(&entry, f).is_empty()) && regular {
                    commands.push(json!({"op":"saveAddress","fields":entry}));
                }
            }
            "remove" => commands.push(json!({"op":"removeAddress","id":id})),
            "fill" if !text(s.active(), "url").is_empty() => {
                commands.push(json!({"op":"fillAddress","id":id}));
                s.menu.clear();
            }
            _ => {}
        },
        "record-shortcut" => s.recording = bound(value, 40),
        "shortcut" => {
            let action = text(r, "action");
            if ACTIONS.iter().any(|a| a.0 == action) {
                if value.is_empty() {
                    commands.push(json!({"op":"setShortcut","action":action,"value":Value::Null}));
                } else if value == "none" || valid_binding(value) {
                    // A key another action uses moves only after the person confirms it.
                    let taken = shortcuts(s).into_iter().find(|(b, a)| b == value && a != action).map(|(_, a)| a);
                    let confirmed = flag(r, "confirm") || text(r, "confirm") == "true";
                    match taken {
                        Some(other) if !confirmed => {
                            s.recording.clear();
                            s.menu = format!("shortcut-conflict:{action}\t{other}\t{value}");
                            return;
                        }
                        Some(other) => commands.push(json!({"op":"setShortcut","action":other,"value":"none"})),
                        None => {}
                    }
                    commands.push(json!({"op":"setShortcut","action":action,"value":value}));
                    s.menu.clear();
                } else {
                    s.notice = "Use at least one of ⌃ ⌥ ⇧ ⌘ with a key, or a function key.".into();
                }
            }
            s.recording.clear();
        }
        "chain" => match value {
            "save" => {
                let steps: Vec<&str> = array(&r["steps"]).iter().filter_map(Value::as_str).filter(|a| ACTIONS.iter().any(|x| x.0 == *a)).take(10).collect();
                if !s.name.trim().is_empty() && steps.len() >= 2 {
                    commands.push(json!({"op":"saveChain","name":bound(&s.name,60),"steps":steps}));
                    s.name.clear();
                } else {
                    s.notice = "Name the chain and choose at least two steps.".into();
                }
            }
            "remove" => commands.push(json!({"op":"removeChain","id":id})),
            _ => {}
        },
        "run-action" => {
            let chain = array(&s.snapshot["preferences"]["commandChains"]).iter().find(|c| c["id"] == r["value"]).cloned();
            let steps: Vec<String> = match &chain {
                Some(c) => array(&c["steps"]).iter().filter_map(Value::as_str).map(str::to_string).collect(),
                None => vec![value.to_string()],
            };
            s.palette = false;
            for step in steps.iter().take(10) {
                if let Some(request) = action_request(s, step) {
                    let result = s.dispatch(request);
                    commands.extend(array(&result["commands"]).iter().cloned());
                }
            }
        }
        "rail-peek" => s.rail_peek = r["value"].as_bool().unwrap_or(false) && s.sidebar_hidden,
        "setting" => {
            let key = text(r, "key");
            let v = &r["value"];
            if valid_setting(key, v) {
                commands.push(json!({"op":"preference","key":key,"value":v}));
            }
        }
        "library-filter" => s.library_filter = bound(value, 80),
        // Vivaldi's Speed Dial groups. A new group lasts once a site is added to it.
        "dial-group" => match value {
            "" => s.dial_group.clear(),
            "new" => {
                let name = bound(s.name.trim(), 40);
                if name.is_empty() || name.contains('/') || name == "Speed Dial" {
                    s.notice = "Give the group a name without a slash.".into();
                } else {
                    s.dial_group = name;
                    s.menu.clear();
                    s.name.clear();
                }
            }
            v if crate::views::dial_groups(s).iter().any(|g| g == v) => s.dial_group = v.into(),
            _ => {}
        },
        "boost" => {
            let Some(site) = site_of_active(s) else { return };
            let css = text(r, "css");
            let js = text(r, "js");
            let hue = r["hue"].as_str().and_then(|h| h.parse::<i64>().ok()).or_else(|| r["hue"].as_i64()).unwrap_or(0).clamp(0, 359);
            let hide: Vec<String> = text(r, "hide").lines().map(str::trim).filter(|l| !l.is_empty()).take(50).map(str::to_string).collect();
            let safe = |v: &str| !v.contains('<') && !v.contains('{') && !v.contains('}') && v.len() <= 200;
            if !regular {
                return;
            }
            if css.len() > 20_000 || js.len() > 20_000 || css.contains('<') || !hide.iter().all(|h| safe(h)) {
                s.notice = "Site styles can’t contain “<”, and each hidden element needs a plain CSS selector.".into();
                return;
            }
            commands.push(json!({"op":"siteBoost","host":site,"css":css,"hide":hide,"js":js,"hue":hue}));
            s.menu.clear();
            s.notice = format!("Styles saved for {site}.");
        }
        "site-reset" => {
            let host = text(r, "host");
            let p = &s.snapshot["preferences"];
            if regular && (p["siteSettings"][host].is_object() || p["siteZoom"][host].is_number()) {
                commands.push(json!({"op":"siteReset","host":host}));
                s.notice = format!("{host} uses your standard settings again.");
            }
        }
        "card" => match value {
            "save" => {
                let number: String = text(r, "number").chars().filter(char::is_ascii_digit).collect();
                let (month, year) = text(r, "expiry").split_once('/').map(|(m, y)| (m.trim().parse::<u32>().unwrap_or(0), y.trim().parse::<u32>().unwrap_or(0))).unwrap_or((0, 0));
                let year = if year < 100 { year + 2000 } else { year };
                if !regular {
                    return;
                }
                if !luhn(&number) || !(1..=12).contains(&month) || !(2000..=2100).contains(&year) {
                    s.notice = "Check the card number and the expiry date (MM/YY).".into();
                    return;
                }
                // A card is valid through the end of its expiry month.
                if let Some(now) = s.snapshot["now"].as_f64().filter(|n| *n > 0.) {
                    if (year, month) < year_month(now) {
                        s.notice = "This card has expired. Check the expiry date (MM/YY).".into();
                        return;
                    }
                }
                commands.push(json!({"op":"saveCard","name":bound(text(r, "name"), 80),"number":number,"month":month,"year":year}));
                s.notice = "Card saved in Keychain.".into();
            }
            "remove" => commands.push(json!({"op":"removeCard","id":r["id"]})),
            "fill" if !text(s.active(), "url").is_empty() => {
                commands.push(json!({"op":"fillCard","id":r["id"]}));
                s.menu.clear();
            }
            "dismiss-offer" => commands.push(json!({"op":"cardOfferDismiss"})),
            _ => {}
        },
        "feed" => {
            let feeds = array(&s.snapshot["preferences"]["feeds"]);
            match value {
                "add" | "subscribe-page" => {
                    let raw = if value == "add" { text(r, "url").trim().to_string() } else { text(&s.snapshot, "pageFeed").to_string() };
                    match Url::parse(&raw) {
                        Ok(url) if regular && ["https", "http"].contains(&url.scheme()) && url.host_str().is_some() => {
                            commands.push(json!({"op":"feedAdd","url":url.as_str()}));
                            s.notice = "Subscribing…".into();
                            s.menu.clear();
                        }
                        _ => s.notice = "Enter the address of an RSS or Atom feed.".into(),
                    }
                }
                "remove" if feeds.iter().any(|f| f["id"] == r["id"]) => commands.push(json!({"op":"feedRemove","id":r["id"]})),
                "refresh" => commands.push(json!({"op":"feedRefresh"})),
                "open" => {
                    let entry = feeds.iter().flat_map(|f| array(&f["entries"]).iter()).find(|e| e["id"] == r["id"]);
                    if let Some(e) = entry {
                        commands.push(json!({"op":"feedOpen","id":e["id"],"url":e["url"]}));
                    }
                }
                "read-all" => commands.push(json!({"op":"feedReadAll"})),
                _ => {}
            }
        }
        "stack-tabs" => {
            let loose = |key: &str| s.tabs().iter().any(|t| text(t, "id") == text(r, key) && !flag(t, "pinned") && text(t, "folderID").is_empty());
            if regular && crate::render::style(s) == "vivaldi" && on(s, "tab-stacks") && text(r, "id") != text(r, "onto") && loose("id") && loose("onto") {
                // ⌘Z puts both tabs back where they were and removes the stack's folder.
                let folders: Vec<Value> = array(&s.snapshot["folders"]).iter().map(|f| f["id"].clone()).collect();
                s.tab_undo.push(json!({"tabs":s.tabs(),"folders":folders}));
                if s.tab_undo.len() > 20 {
                    s.tab_undo.remove(0);
                }
                commands.push(json!({"op":"stackTabs","id":r["id"],"onto":r["onto"]}));
                s.notice = "Tabs stacked. Undo is available.".into();
            }
        }
        "tab-preview" => {
            let known = s.tabs().iter().any(|t| t["id"] == id);
            if on(s, "tab-previews") && (known || value == "hide") {
                let rect = &r["rect"];
                let valid = ["x", "y", "w", "h"].iter().all(|k| rect[k].as_f64().is_some_and(|v| v.is_finite() && v.abs() < 100_000.));
                let placement = if !crate::render::horizontal(s) { "beside" } else if text(&s.config()["layout"], "tabs") == "bottom" { "above" } else { "below" };
                commands.push(json!({"op":"tabPreview","id":if known {id.clone()} else {Value::Null},"rect":if valid {rect.clone()} else {Value::Null},"placement":placement}));
            }
        }
        "move-bookmark" => {
            let index = array(&s.snapshot["bookmarkIndex"]);
            let known = |key: &str| index.iter().any(|b| text(b, "id") == text(r, key));
            if regular && known("id") && (r["before"].is_null() || known("before")) {
                let folder = r["folder"].as_str().map(|f| f.trim().trim_matches('/')).filter(|f| f.len() <= 160);
                commands.push(json!({"op":"moveBookmark","id":r["id"],"before":r["before"],"folder":folder}));
            }
        }
        "password-prompt" => {
            if ["save", "never", "dismiss"].contains(&value) && s.snapshot["passwordPrompt"].is_object() {
                commands.push(json!({"op":"passwordPrompt","value":value}));
            }
        }
        "filter-list" => {
            if !regular {
                return;
            }
            match value {
                "toggle" => {
                    let id = text(r, "id");
                    let custom = array(&s.snapshot["preferences"]["filterLists"]).iter().any(|l| text(l, "id") == id);
                    if let Some((id, title, url, _)) = FILTER_LISTS.iter().find(|l| l.0 == id) {
                        commands.push(json!({"op":"filterList","action":"toggle","id":id,"title":title,"url":url}));
                    } else if custom {
                        commands.push(json!({"op":"filterList","action":"toggle","id":id}));
                    }
                }
                "add" => match Url::parse(text(r, "url").trim()) {
                    Ok(url) if url.scheme() == "https" && url.host_str().is_some() => {
                        commands.push(json!({"op":"filterList","action":"add","url":url.as_str()}));
                        s.notice = "Downloading the list…".into();
                    }
                    _ => s.notice = "Enter the https:// address of a filter list.".into(),
                },
                "remove" => commands.push(json!({"op":"filterList","action":"remove","id":text(r, "id")})),
                "refresh" => {
                    commands.push(json!({"op":"filterList","action":"refresh"}));
                    s.notice = "Updating filter lists…".into();
                }
                _ => {}
            }
        }
        "link-route" => {
            let mut routes: Vec<Value> = array(&s.snapshot["preferences"]["linkRoutes"]).to_vec();
            match value {
                "add" => {
                    let host = text(r, "host").trim().trim_start_matches("https://").trim_start_matches("http://").trim_start_matches("www.").trim_end_matches('/').to_ascii_lowercase();
                    let space = text(r, "space");
                    let known = array(&s.snapshot["spaces"]).iter().any(|v| text(v, "id") == space && v["profileID"] == s.snapshot["session"]["profileID"]);
                    let valid = host.contains('.') && host.len() <= 253 && host.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-');
                    if !regular || !known || !valid {
                        s.notice = "Enter a site such as github.com and choose a Space.".into();
                        return;
                    }
                    routes.retain(|v| text(v, "host") != host);
                    routes.push(json!({"host":host,"spaceID":space}));
                    routes.truncate(50);
                }
                "remove" => {
                    let Some(index) = r["index"].as_u64().map(|i| i as usize).filter(|i| *i < routes.len()) else { return };
                    routes.remove(index);
                }
                _ => return,
            }
            commands.push(json!({"op":"preference","key":"linkRoutes","value":routes}));
        }
        "startup-pages" => {
            let pages: Vec<String> = value.lines().map(str::trim).filter(|l| !l.is_empty()).take(20).filter_map(web_address).collect();
            commands.push(json!({"op":"preference","key":"startupPages","value":pages}));
            commands.push(json!({"op":"preference","key":"restoreSession","value":false}));
        }
        "tidy-tabs" => {
            if s.snapshot["preferences"]["ai"].is_null() {
                s.notice = "Set up an AI provider in Settings → AI providers to tidy tabs.".into();
            } else if regular {
                commands.push(json!({"op":"tidyTabs"}));
                s.notice = "Grouping tabs…".into();
            }
            s.menu.clear();
        }
        "split-ratio" => {
            if let Some(v) = r["value"].as_f64().filter(|v| (0.2..=0.8).contains(v)) {
                commands.push(json!({"op":"splitRatio","value":v}));
            }
        }
        _ => {}
    }
}

/// Address suggestions: open tabs, then bookmarks and history the host found.
pub fn suggestions(s: &Shell) -> Vec<Value> {
    let query = s.address_query.to_lowercase();
    if query.is_empty() {
        return vec![];
    }
    let mut out = vec![];
    let mut seen = std::collections::HashSet::new();
    for t in s.tabs() {
        let url = text(t, "url");
        if !url.is_empty() && t["id"] != s.active()["id"] && (text(t, "title").to_lowercase().contains(&query) || url.to_lowercase().contains(&query)) && seen.insert(url.to_string()) {
            out.push(json!({"kind":"tab","id":t["id"],"title":t["title"],"url":url}));
        }
        if out.len() == 2 {
            break;
        }
    }
    for item in array(&s.snapshot["suggestions"]) {
        let url = text(item, "url");
        if !url.is_empty() && seen.insert(url.to_string()) {
            out.push(item.clone());
        }
        if out.len() == 7 {
            break;
        }
    }
    out
}

/// Common consent-banner containers, hidden when the person turns that on.
/// Covers the widely used consent managers; Fanboy's Annoyance list adds more.
const COOKIE_BANNERS: &[&str] = &[
    "#onetrust-consent-sdk", "#onetrust-banner-sdk", "#CybotCookiebotDialog", "#CybotCookiebotDialogBodyUnderlay",
    ".qc-cmp2-container", "#qc-cmp2-container", "#didomi-host", "#usercentrics-root", ".fc-consent-root", "#cmpbox",
    "#cmpwrapper", ".cc-window", ".cc-banner", "#cookie-law-info-bar", "#cookie-notice", "#cookie-banner",
    ".cookie-banner", "#gdpr-cookie-message", "#truste-consent-track", ".truste_box_overlay", ".truste_overlay",
    "[id^='sp_message_container_']", "#BorlabsCookieBox", "#iubenda-cs-banner", ".osano-cm-window",
    "#termly-code-snippet-support", "#_evidon_banner", ".evidon-banner", "#consent_blackbar",
    "#cookiescript_injected", "#hs-eu-cookie-confirmation", "#axeptio_overlay", "#tarteaucitronRoot",
    "#cookie-consent-banner", "[aria-label='cookieconsent']", ".cookie-consent-banner", "#uc-banner-modal",
    ".didomi-popup-open .didomi-popup-backdrop", "#cmpbox2", ".cmp-root", "#cliSettingsPopup",
    ".cky-consent-container", ".cky-overlay", "#moove_gdpr_cookie_info_bar", ".gdpr-cookie-notice", "#cookieNotice",
    ".cookie-notice", "#cookiebanner", ".cookiebanner", "#cookie-bar", ".cookie-bar", "#cookies-banner",
    ".cookies-banner", "#cookieConsent", ".cookieConsent", "#cookie-popup", ".cookie-popup", "#cc-main",
    ".cm-wrapper", "#klaro", ".klaro .cookie-notice", ".iubenda-cs-container", "#consent-banner", ".consent-banner",
    "#js-consent-banner", ".sp-message-open #sp_message_container", "#ccc", "#ccc-overlay", ".osano-cm-dialog",
    ".t-consentPrompt", "#coiOverlay", "#CookieReportsBanner", "[data-testid='cookie-banner']",
    "[id^='cookie-consent']", "#onetrust-pc-sdk", ".onetrust-pc-dark-filter", ".optanon-alert-box-wrapper",
    "#usercentrics-cmp-ui", "#uc-center-container", ".cmplz-cookiebanner", "#cmplz-cookiebanner-container",
    "#cookiefirst-root", ".ch2-container", "#cookie-information-template-wrapper", ".cookieconsent-com---nb",
    "#fides-overlay", ".fides-banner", "#lanyard_root", "#transcend-consent-manager", ".ppms_cm_popup_overlay",
    "#ppms_cm_popup_overlay", "#__tealiumGDPRecModal", "#tc-privacy-wrapper", "#footer_tc_privacy", "#sd-cmp",
    "#appconsent", ".cmpboxBG", "#sliding-popup", ".eu-cookie-compliance-banner", "#cookieChoiceInfo",
    "#shopify-pc__banner", "#pandectes-banner", "#consent-tracking", ".cookie-law-info-bar", "#catapult-cookie-bar",
    "#cn-notice-text", ".cn-notice-container", "#cookie-notice-container", "#gdpr-consent-tool-wrapper",
    ".js-cookie-consent", "#cookie-notification", ".cookie-notification", "#cookieWall", "#didomi-notice",
    "#gdpr-banner", ".gdpr-banner",
];
/// Classes consent managers put on the page to stop it scrolling while their banner shows.
const COOKIE_SCROLL_LOCKS: &[&str] = &[
    "html.sp-message-open", "body.didomi-popup-open", "body.qc-cmp-showing", "body.cmp-pop-open", "html.cmplz-blocked",
    "body.cky-modal-open", "body.uc-banner-active", "html.ppms_cm_popup_overlay_open", "body.ch2-scroll-lock", "body.cookiefirst-scroll-lock",
];

/// Scripts the host runs in an isolated world on a page. Each returns a string.
pub fn page_script(r: &Value) -> Option<String> {
    let quote = |v: &str| serde_json::to_string(v).unwrap_or_else(|_| "\"\"".into());
    Some(match text(r, "kind") {
        "style" => {
            let settings = &r["settings"];
            let mut css = match text(settings, "filter") {
                "dark" => "html{filter:invert(1) hue-rotate(180deg)!important;background:#fff!important}img,video,picture,canvas,iframe,embed,object{filter:invert(1) hue-rotate(180deg)!important}".to_string(),
                "grayscale" => "html{filter:grayscale(1)!important}".into(),
                "sepia" => "html{filter:sepia(.7)!important}".into(),
                "invert" => "html{filter:invert(1)!important}".into(),
                "contrast" => "html{filter:contrast(1.35)!important}".into(),
                "noimages" => "img,picture,video,svg image,[role=img]{visibility:hidden!important}".into(),
                _ => String::new(),
            };
            for selector in array(&settings["hide"]).iter().filter_map(Value::as_str).take(50) {
                if !selector.contains(['<', '{', '}']) && selector.len() <= 200 {
                    css.push_str(&format!("{selector}{{display:none!important}}"));
                }
            }
            if let Some(hue) = settings["hue"].as_i64().filter(|h| (1..360).contains(h)) {
                css.push_str(&format!("body{{filter:hue-rotate({hue}deg)!important}}"));
            }
            let custom = text(settings, "css");
            if custom.len() <= 20_000 && !custom.contains('<') {
                css.push_str(custom);
            }
            if flag(r, "cookieBanners") {
                for selector in COOKIE_BANNERS {
                    css.push_str(&format!("{selector}{{display:none!important}}"));
                }
                for selector in COOKIE_SCROLL_LOCKS {
                    css.push_str(&format!("{selector}{{overflow:auto!important}}"));
                }
            }
            for selector in cosmetic_for(array(&r["cosmetic"]), text(r, "site")) {
                css.push_str(&format!("{selector}{{display:none!important}}"));
            }
            format!("(()=>{{const id='neutrino-page-style';let s=document.getElementById(id);const css={};if(!css){{s?.remove();return 'none'}}if(!s){{s=document.createElement('style');s.id=id;(document.head||document.documentElement).appendChild(s)}}if(s.textContent!==css)s.textContent=css;return 'applied'}})()", quote(&css))
        }
        "mute" => format!("(()=>{{const m={};window.__neutrinoMuted=m;const all=()=>document.querySelectorAll('video,audio').forEach(e=>{{if(m)e.muted=true;else if(e.dataset.neutrinoMuted)e.muted=false;if(m)e.dataset.neutrinoMuted='1';else delete e.dataset.neutrinoMuted}});all();if(!window.__neutrinoMuteObserver){{window.__neutrinoMuteObserver=true;document.addEventListener('play',e=>{{if(window.__neutrinoMuted&&e.target instanceof HTMLMediaElement){{e.target.muted=true;e.target.dataset.neutrinoMuted='1'}}}},true)}}return String(m)}})()", flag(r, "value")),
        // Fills a payment form's name, number and expiry by their autocomplete hints or names.
        "fillCard" => {
            let card = &r["card"];
            format!("(()=>{{const c={};const set=(e,v)=>{{if(!e||!v)return 0;const s=Object.getOwnPropertyDescriptor(Object.getPrototypeOf(e),'value').set;s.call(e,v);e.dispatchEvent(new Event('input',{{bubbles:true}}));e.dispatchEvent(new Event('change',{{bubbles:true}}));return 1}};const q=(ac,re)=>document.querySelector('[autocomplete~=\"'+ac+'\"]')||[...document.querySelectorAll('input,select')].find(e=>re.test((e.name||'')+' '+(e.id||'')+' '+(e.getAttribute('aria-label')||'')));if(location.protocol!=='https:')return '0';let n=0;n+=set(q('cc-name',/card.?holder|name.?on.?card|cc.?name/i),c.name);n+=set(q('cc-number',/card.?number|cc.?num|cardnumber/i),c.number);const mm=String(c.month).padStart(2,'0'),yy=String(c.year);const exp=q('cc-exp',/exp(iry|iration)?(.?date)?$|mm.?yy/i);if(exp&&exp.tagName!=='SELECT')n+=set(exp,mm+'/'+yy.slice(2));else{{n+=set(q('cc-exp-month',/exp.?month|cc.?month/i),mm);const y=q('cc-exp-year',/exp.?year|cc.?year/i);n+=set(y,y&&y.maxLength===2?yy.slice(2):yy)}}return String(n)}})()", serde_json::to_string(card).unwrap_or_else(|_| "{}".into()))
        }
        // Reports a submitted sign-in to Neutrino from its own isolated world, so the
        // page can't call the reporter. WebKit uses a message handler, Chromium a binding.
        "credentialCapture" => "(()=>{if(window.__neutrinoCredentials||window.top!==window)return 'off';window.__neutrinoCredentials=true;const send=o=>{try{if(window.webkit&&webkit.messageHandlers&&webkit.messageHandlers.neutrinoCredential)webkit.messageHandlers.neutrinoCredential.postMessage(o);else if(typeof neutrinoCredential==='function')neutrinoCredential(JSON.stringify(o))}catch(_){}};let last='';const capture=form=>{const root=form||document;const pw=[...root.querySelectorAll('input[type=password]')].find(i=>i.value);if(!pw)return;const inputs=[...(pw.form||root).querySelectorAll('input')];let user='';for(let i=inputs.indexOf(pw)-1;i>=0;i--){const t=(inputs[i].type||'text').toLowerCase();if(['text','email','tel'].includes(t)&&inputs[i].value){user=inputs[i].value;break}}if(!user){const u=document.querySelector('input[autocomplete=username],input[type=email]');user=(u&&u.value)||''}const key=user+'\\n'+pw.value;if(key===last)return;last=key;send({origin:location.origin,username:user.slice(0,200),password:pw.value.slice(0,500)})};addEventListener('submit',e=>capture(e.target),true);addEventListener('click',e=>{const b=e.target&&e.target.closest&&e.target.closest('button,input[type=submit],[role=button]');if(b&&(b.form||document).querySelector('input[type=password]'))setTimeout(()=>capture(b.form),0)},true);addEventListener('keydown',e=>{if(e.key==='Enter'&&e.target&&e.target.form&&e.target.form.querySelector('input[type=password]'))capture(e.target.form)},true);return 'on'})()".into(),
        // WebKit content rules don't report matches, so count the page's
        // third-party resources from blocked domains: an estimate of what was blocked.
        "blockedCount" => {
            let domains: Vec<&str> = array(&r["domains"]).iter().filter_map(Value::as_str).filter(|d| d.len() <= 253 && d.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')).take(20_000).collect();
            format!("(()=>{{const d=new Set({});const hit=h=>{{for(let p=h.toLowerCase();p;){{if(d.has(p))return true;const i=p.indexOf('.');if(i<0)return false;p=p.slice(i+1)}}return false}};const seen=new Set();for(const e of document.querySelectorAll('script[src],img[src],iframe[src],link[href][rel~=stylesheet],embed[src],source[src],video[src],audio[src]')){{try{{const x=new URL(e.getAttribute('src')||e.getAttribute('href'),location.href);if(x.hostname!==location.hostname&&hit(x.hostname))seen.add(x.href)}}catch(_){{}}}}return String(seen.size)}})()", serde_json::to_string(&domains).unwrap_or_else(|_| "[]".into()))
        }
        // Brave-style fingerprinting protection, run in the page's own world before its scripts:
        // per-site, per-session noise in canvas and audio readouts, a generic WebGL renderer and
        // fewer reported cores. Wrapped functions report the original's source to toString.
        "farbling" => {
            let seed: String = text(r, "seed").chars().filter(|c| c.is_ascii_alphanumeric()).take(64).collect();
            let off: Vec<&str> = array(&r["exceptions"]).iter().filter_map(Value::as_str).filter(|h| h.len() <= 253 && h.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')).take(500).collect();
            format!(r#"(()=>{{if(window.__neutrinoFarbling)return;window.__neutrinoFarbling=1;const host=(location.hostname||'').toLowerCase();const site=host.split('.').slice(-2).join('.');const off={};if(off.includes(host)||off.includes(site))return;let seed=2166136261;for(const c of {}+'|'+site){{seed^=c.charCodeAt(0);seed=Math.imul(seed,16777619)}}const hash=(n)=>{{let x=(seed^Math.imul(n+1,2654435761))>>>0;x^=x>>>16;x=Math.imul(x,2246822507)>>>0;x^=x>>>13;return x>>>0}};const nativeToString=Function.prototype.toString;const originals=new WeakMap();const wrap=(fn,original)=>{{originals.set(fn,original);return fn}};Function.prototype.toString=wrap(function toString(){{return nativeToString.call(originals.get(this)||this)}},nativeToString);const farble=(data)=>{{const pixels=data.length>>2;if(!pixels)return;for(let i=0;i<8;i++){{const h=hash(i);const p=(h%pixels)*4+(h>>>24)%3;data[p]^=1}}}};const _getImageData=CanvasRenderingContext2D.prototype.getImageData;const _toDataURL=HTMLCanvasElement.prototype.toDataURL;const _toBlob=HTMLCanvasElement.prototype.toBlob;const copy=(canvas)=>{{try{{const w=canvas.width,h=canvas.height;if(!w||!h||w*h>16e6)return canvas;const c=document.createElement('canvas');c.width=w;c.height=h;const x=c.getContext('2d');x.drawImage(canvas,0,0);const d=_getImageData.call(x,0,0,w,h);farble(d.data);x.putImageData(d,0,0);return c}}catch(_){{return canvas}}}};CanvasRenderingContext2D.prototype.getImageData=wrap(function getImageData(...a){{const d=_getImageData.apply(this,a);farble(d.data);return d}},_getImageData);HTMLCanvasElement.prototype.toDataURL=wrap(function toDataURL(...a){{return _toDataURL.apply(copy(this),a)}},_toDataURL);HTMLCanvasElement.prototype.toBlob=wrap(function toBlob(...a){{return _toBlob.apply(copy(this),a)}},_toBlob);for(const proto of [window.WebGLRenderingContext,window.WebGL2RenderingContext].filter(Boolean).map(c=>c.prototype)){{const _getParameter=proto.getParameter;proto.getParameter=wrap(function getParameter(p){{if(p===37445)return 'Apple Inc.';if(p===37446)return 'Apple GPU';return _getParameter.call(this,p)}},_getParameter)}}const fudge=1+((hash(7)%1000)-500)*1e-7;if(window.AudioBuffer){{const _getChannelData=AudioBuffer.prototype.getChannelData;const done=new WeakSet();AudioBuffer.prototype.getChannelData=wrap(function getChannelData(...a){{const d=_getChannelData.apply(this,a);if(!done.has(d)){{done.add(d);for(let i=0;i<d.length;i++)d[i]*=fudge}}return d}},_getChannelData)}}if(window.AnalyserNode){{const getFloat=AnalyserNode.prototype.getFloatFrequencyData;AnalyserNode.prototype.getFloatFrequencyData=wrap(function getFloatFrequencyData(array){{getFloat.call(this,array);for(let i=0;i<array.length;i++)array[i]*=fudge}},getFloat)}}const cores=navigator.hardwareConcurrency||4;const shown=Math.max(2,Math.min(cores,2+hash(99)%Math.max(1,cores-1)));try{{const real=Object.getOwnPropertyDescriptor(Navigator.prototype,'hardwareConcurrency');Object.defineProperty(Navigator.prototype,'hardwareConcurrency',{{get:wrap(function get(){{return shown}},real&&real.get||nativeToString),configurable:true,enumerable:true}})}}catch(_){{}}}})()"#, serde_json::to_string(&off).unwrap_or_else(|_| "[]".into()), quote(&seed))
        }
        // The article's large images for Reader, each with the start of the paragraph it follows.
        "readerImages" => "(()=>{const root=document.querySelector('article')||document.querySelector('main')||document.body;if(!root)return '[]';const blocks=new Set(['P','H1','H2','H3','H4','H5','H6','LI','BLOCKQUOTE','PRE']);const out=[];const seen=new Set();for(const img of root.querySelectorAll('img')){if(out.length>=12)break;const src=img.currentSrc||img.src;if(!/^https?:/.test(src)||seen.has(src))continue;const w=img.naturalWidth||img.width,h=img.naturalHeight||img.height,shown=img.getBoundingClientRect();if(w<200||h<120||shown.width<100||shown.height<60||img.closest('nav,footer,aside,form'))continue;seen.add(src);let anchor='';const walk=document.createTreeWalker(root,NodeFilter.SHOW_ELEMENT);walk.currentNode=img;while(walk.previousNode()){const e=walk.currentNode;if(blocks.has(e.tagName)&&!e.contains(img)){const t=(e.innerText||'').trim().replace(/\\s+/g,' ');if(t){anchor=t.slice(0,80);break}}}out.push({src,alt:(img.alt||'').slice(0,200),anchor})}return JSON.stringify(out)})()".into(),
        // Third-party hosts the page loads resources from, with how many each: {host: count}.
        "resourceHosts" => "(()=>{const out={};const seen=new Set();for(const e of document.querySelectorAll('script[src],img[src],iframe[src],link[href][rel~=stylesheet],embed[src],source[src],video[src],audio[src]')){try{const x=new URL(e.getAttribute('src')||e.getAttribute('href'),location.href);if(x.hostname===location.hostname||seen.has(x.href))continue;seen.add(x.href);const h=x.hostname.toLowerCase();if(!(h in out)&&Object.keys(out).length>=500)continue;out[h]=(out[h]||0)+1}catch(_){}}return JSON.stringify(out)})()".into(),
        // The RSS or Atom feed a page advertises in its head, or "".
        // Brave's De-AMP: an AMP page's own canonical article, when it names one elsewhere.
        "deAmp" => "(()=>{const h=document.documentElement;if(!h||!(h.hasAttribute('amp')||h.hasAttribute('\\u26a1')))return '';const l=document.querySelector('link[rel~=canonical][href]');if(!l)return '';const c=new URL(l.href,location.href);return /^https?:$/.test(c.protocol)&&c.href!==location.href?c.href:''})()".into(),
        // A visible payment-card field on a secure page, so Neutrino can offer a saved card.
        "cardForm" => "(()=>{if(location.protocol!=='https:')return '';const f=document.querySelector('input[autocomplete~=cc-number],input[name*=cardnumber i],input[id*=cardnumber i],input[name*=card_number i],input[id*=card-number i]');if(!f)return '';const r=f.getBoundingClientRect();return r.width>0&&r.height>0?'1':''})()".into(),
        "feedLink" => "(()=>{const l=document.querySelector('link[rel~=alternate][href][type=\"application/rss+xml\"],link[rel~=alternate][href][type=\"application/atom+xml\"]');return l&&/^https?:/.test(l.href)?l.href:''})()".into(),
        // Vivaldi's Fast Forward: the next page in a series, or "".
        "nextPage" => "(()=>{const a=document.querySelector('link[rel~=next][href],a[rel~=next][href]');if(a)return a.href;const words=/^(next|next page|older|older posts|more|weiter|suivant|siguiente|›|»|>|→)$/i;for(const e of document.querySelectorAll('a[href]')){const t=(e.innerText||e.getAttribute('aria-label')||'').trim();if(t.length<20&&words.test(t)&&!e.href.startsWith('javascript:'))return e.href}return ''})()".into(),
        // Vivaldi's spatial navigation: Shift with an arrow key moves between links.
        "spatialNavigation" => "(()=>{if(window.__neutrinoSpatial)return 'on';window.__neutrinoSpatial=true;addEventListener('keydown',e=>{if(!e.shiftKey||e.metaKey||e.ctrlKey||e.altKey)return;const dir={ArrowLeft:[-1,0],ArrowRight:[1,0],ArrowUp:[0,-1],ArrowDown:[0,1]}[e.key];if(!dir)return;const t=e.target;if(t&&(t.isContentEditable||/^(input|textarea|select)$/i.test(t.tagName)))return;const all=[...document.querySelectorAll('a[href],button,[tabindex]:not([tabindex=\"-1\"])')].filter(n=>{const r=n.getBoundingClientRect();return r.width>0&&r.height>0&&r.bottom>0&&r.top<innerHeight});const cur=document.activeElement&&document.activeElement!==document.body?document.activeElement.getBoundingClientRect():{left:innerWidth/2,top:innerHeight/2,width:0,height:0};const cx=cur.left+cur.width/2,cy=cur.top+cur.height/2;let best=null,score=1e9;for(const n of all){if(n===document.activeElement)continue;const r=n.getBoundingClientRect(),x=r.left+r.width/2-cx,y=r.top+r.height/2-cy;const along=x*dir[0]+y*dir[1];if(along<=1)continue;const across=Math.abs(x*dir[1]+y*dir[0]);const d=along+across*2;if(d<score){score=d;best=n}}if(best){e.preventDefault();best.focus({preventScroll:false});best.scrollIntoView({block:'nearest',inline:'nearest'})}},true);return 'on'})()".into(),
        // Resolves with a selector for the element the person clicks, or "" on Escape.
        "pick" => {
            let label = match text(r, "label") {
                "" => "Click an element to hide it on this site. Press Esc to cancel.",
                other => other,
            };
            format!(
                "new Promise(done=>{{const d=document,root=d.documentElement,ok=/^[A-Za-z_][\\w-]*$/,box=d.createElement('div'),tip=d.createElement('div');\
box.style.cssText='position:fixed;z-index:2147483647;pointer-events:none;box-sizing:border-box;border:2px solid #3b82f6;background:rgba(59,130,246,.14);border-radius:4px;transition:left .06s,top .06s,width .06s,height .06s;left:0;top:0;width:0;height:0';\
tip.textContent={};tip.style.cssText='position:fixed;z-index:2147483647;left:50%;top:12px;transform:translateX(-50%);padding:6px 12px;border-radius:8px;background:rgba(20,20,22,.9);color:#fff;font:13px -apple-system,system-ui,sans-serif;pointer-events:none';\
root.append(box,tip);let target=null;\
const same=e=>[...(e.parentElement?.children||[])].filter(x=>x.localName===e.localName);\
const name=e=>{{if(e.id&&ok.test(e.id)&&d.querySelectorAll('#'+e.id).length===1)return '#'+e.id;let s=e.localName;const c=[...e.classList].filter(x=>ok.test(x)).slice(0,2);if(c.length)s+='.'+c.join('.');const sib=same(e);if(sib.length>1)s+=':nth-of-type('+(sib.indexOf(e)+1)+')';return s}};\
const path=e=>{{const parts=[];for(let n=e;n&&n!==d.body&&n!==root&&parts.length<6;n=n.parentElement){{const part=name(n);parts.unshift(part);if(part[0]==='#'||d.querySelectorAll(parts.join(' > ')).length===1)break}}return parts.join(' > ')}};\
const move=e=>{{const t=e.target;if(!(t instanceof Element)||t===box||t===tip)return;target=t;const r=t.getBoundingClientRect();Object.assign(box.style,{{left:r.left+'px',top:r.top+'px',width:r.width+'px',height:r.height+'px'}})}};\
const stop=e=>{{e.preventDefault();e.stopPropagation();e.stopImmediatePropagation()}};\
const kinds=['mousedown','mouseup','pointerdown','pointerup','auxclick','contextmenu'];\
const end=v=>{{removeEventListener('mousemove',move,true);kinds.forEach(k=>removeEventListener(k,stop,true));removeEventListener('click',click,true);removeEventListener('keydown',key,true);clearTimeout(timer);box.remove();tip.remove();done(v)}};\
const click=e=>{{stop(e);end(target&&target!==root&&target!==d.body?path(target):'')}};\
const key=e=>{{if(e.key==='Escape'){{stop(e);end('')}}}};\
addEventListener('mousemove',move,true);kinds.forEach(k=>addEventListener(k,stop,true));addEventListener('click',click,true);addEventListener('keydown',key,true);\
const timer=setTimeout(()=>end(''),100000)}})",
                quote(label)
            )
        }
        "mediaState" =>"(()=>{const ms=[...document.querySelectorAll('video,audio')];const p=ms.find(m=>!m.paused&&!m.ended&&m.readyState>2);return JSON.stringify({audible:!!p&&!p.muted&&p.volume>0,playing:!!p,media:ms.length>0,ended:!p&&ms.some(m=>m.ended&&m.duration>20),title:(navigator.mediaSession&&navigator.mediaSession.metadata&&navigator.mediaSession.metadata.title)||''})})()".into(),
        "mediaToggle" => "(()=>{const ms=[...document.querySelectorAll('video,audio')];const p=ms.find(m=>!m.paused&&!m.ended);if(p){p.pause();return 'paused'}const q=ms.find(m=>m.currentTime>0&&!m.ended)||ms[0];if(q){q.play();return 'playing'}return 'none'})()".into(),
        // Hold Option and drag: left goes back, right forward, up then down reloads,
        // up or down scrolls to the top or bottom.
        "gestures" => "(()=>{if(window.__neutrinoGestures)return 'ready';window.__neutrinoGestures=true;let start=null,path=[],moved=false;addEventListener('mousedown',e=>{if(e.button===0&&e.altKey){start=[e.clientX,e.clientY];path=[];moved=false}},true);addEventListener('mousemove',e=>{if(!start||!(e.buttons&1))return;const dx=e.clientX-start[0],dy=e.clientY-start[1];if(Math.hypot(dx,dy)<40)return;const d=Math.abs(dx)>Math.abs(dy)?(dx>0?'R':'L'):(dy>0?'D':'U');if(path[path.length-1]!==d)path.push(d);start=[e.clientX,e.clientY];if(!moved){moved=true;getSelection()&&getSelection().removeAllRanges();document.documentElement.style.userSelect='none'}},true);addEventListener('mouseup',()=>{if(!start)return;start=null;document.documentElement.style.userSelect='';if(!moved)return;const g=path.join('');addEventListener('click',e=>{e.preventDefault();e.stopPropagation()},{capture:true,once:true});if(g==='L')history.back();else if(g==='R')history.forward();else if(g==='UD')location.reload();else if(g==='U')scrollTo({top:0,behavior:'smooth'});else if(g==='D')scrollTo({top:document.documentElement.scrollHeight,behavior:'smooth'})},true);return 'installed'})()".into(),
        "pauseAll" => "(()=>{document.querySelectorAll('video,audio').forEach(m=>m.pause());return 'paused'})()".into(),
        "pip" => "(()=>{if(document.pictureInPictureElement){document.exitPictureInPicture();return 'exit'}const vs=[...document.querySelectorAll('video')].filter(v=>v.readyState>0).sort((a,b)=>b.clientWidth*b.clientHeight-a.clientWidth*a.clientHeight);const v=vs.find(v=>!v.paused)||vs[0];if(!v)return 'none';if(v.requestPictureInPicture){v.disablePictureInPicture=false;v.requestPictureInPicture();return 'pip'}if(v.webkitSetPresentationMode){v.webkitSetPresentationMode('picture-in-picture');return 'pip'}return 'none'})()".into(),
        "findCount" => format!("(()=>{{const q={}.toLowerCase();if(!q)return '0';const t=(document.body&&document.body.innerText||'').toLowerCase();let n=0,i=0;while((i=t.indexOf(q,i))!==-1&&n<9999){{n++;i+=q.length}}return String(n)}})()", quote(text(r, "query"))),
        "fillAddress" => {
            let a = &r["address"];
            let fields = json!({
                "name": text(a, "name"), "organization": text(a, "organization"), "street-address": text(a, "street"),
                "address-line1": text(a, "street"), "address-level2": text(a, "city"), "address-level1": text(a, "region"),
                "postal-code": text(a, "postalCode"), "country-name": text(a, "country"), "country": text(a, "country"),
                "email": text(a, "email"), "tel": text(a, "phone")
            });
            format!("(()=>{{const f={fields};const guess=e=>{{const k=((e.name||'')+' '+(e.id||'')+' '+(e.getAttribute('aria-label')||'')+' '+(e.placeholder||'')).toLowerCase();if(/e-?mail/.test(k))return 'email';if(/phone|tel/.test(k))return 'tel';if(/zip|postal/.test(k))return 'postal-code';if(/city|town/.test(k))return 'address-level2';if(/state|region|province|county/.test(k))return 'address-level1';if(/country/.test(k))return 'country-name';if(/address|street/.test(k))return 'street-address';if(/company|organi/.test(k))return 'organization';if(/name/.test(k))return 'name';return ''}};let n=0;document.querySelectorAll('input,textarea,select').forEach(e=>{{if(e.disabled||e.readOnly||e.type==='hidden'||e.type==='password')return;const token=(e.autocomplete||'').split(' ').pop();const key=f[token]!==undefined?token:guess(e);const v=f[key];if(!v)return;const setter=Object.getOwnPropertyDescriptor(Object.getPrototypeOf(e),'value')?.set;setter?setter.call(e,v):e.value=v;e.dispatchEvent(new Event('input',{{bubbles:true}}));e.dispatchEvent(new Event('change',{{bubbles:true}}));n++}});return String(n)}})()")
        }
        _ => return None,
    })
}

pub const WEB_PANEL_SITES: &[(&str, &str)] = &[
    ("WhatsApp", "https://web.whatsapp.com/"),
    ("Telegram", "https://web.telegram.org/"),
    ("Messenger", "https://www.messenger.com/"),
    ("Discord", "https://discord.com/app"),
    ("X", "https://x.com/"),
    ("Instagram", "https://www.instagram.com/"),
    ("Spotify", "https://open.spotify.com/"),
    ("Twitch", "https://www.twitch.tv/"),
    ("YouTube Music", "https://music.youtube.com/"),
    ("Gmail", "https://mail.google.com/"),
    ("Calendar", "https://calendar.google.com/"),
    ("ChatGPT", "https://chatgpt.com/"),
];

pub const FOLDER_COLORS: &[(&str, &str)] = &[
    ("grey", "Grey"), ("blue", "Blue"), ("red", "Red"), ("yellow", "Yellow"),
    ("green", "Green"), ("pink", "Pink"), ("purple", "Purple"), ("cyan", "Cyan"),
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_campaign_parameters_and_keeps_the_rest() {
        assert_eq!(strip_tracking("https://example.com/a?utm_source=x&id=7&fbclid=1").as_deref(), Some("https://example.com/a?id=7"));
        assert_eq!(strip_tracking("https://example.com/?gclid=1").as_deref(), Some("https://example.com/"));
        assert_eq!(strip_tracking("https://example.com/?q=rust"), None);
        assert_eq!(strip_tracking("https://youtu.be/abc?si=share").as_deref(), Some("https://youtu.be/abc"));
        assert_eq!(strip_tracking("https://www.google.com/amp/s/news.example.com/story.amp.html").as_deref(), Some("https://news.example.com/story.amp.html"));
        assert_eq!(strip_tracking("https://news-example-com.cdn.ampproject.org/c/s/news.example.com/a?utm_source=x").as_deref(), Some("https://news.example.com/a"));
    }

    #[test]
    fn reads_domains_from_filter_lists_and_hosts_files() {
        let rules = "! comment\n||ads.example.com^\n0.0.0.0 tracker.example.net\nplain.example.org\n##.banner\n||cdn.example.com^$script\n@@||good.example.com^\nlocalhost\n||pixel.example.io^$third-party\n||shop.example.com^$domain=a.com\n||cdn.example.com/ads.js\n";
        assert_eq!(parse_rules(rules), vec!["ads.example.com", "tracker.example.net", "plain.example.org", "pixel.example.io"]);
    }

    #[test]
    fn card_numbers_need_a_valid_check_digit() {
        assert!(luhn("4242424242424242"));
        assert!(luhn("5555 5555 5555 4444".replace(' ', "").as_str()));
        assert!(!luhn("4242424242424241"));
        assert!(!luhn("1234"));
    }

    #[test]
    fn element_hiding_rules_apply_by_site() {
        let rules = "##.banner\nnews.example,~shop.news.example##.promo\nexample.org#@#.keep\nexample.org##+js(noop)\nexample.org##div:has-text(Ad)\nbad##a{color:red}\n";
        let parsed = parse_cosmetic(rules);
        assert_eq!(parsed, vec!["##.banner", "news.example,~shop.news.example##.promo"]);
        let stored: Vec<Value> = parsed.into_iter().map(Value::from).collect();
        assert_eq!(cosmetic_for(&stored, "www.news.example"), vec![".banner", ".promo"]);
        assert_eq!(cosmetic_for(&stored, "shop.news.example"), vec![".banner"]);
        assert_eq!(cosmetic_for(&stored, "other.example"), vec![".banner"]);
        let style = page_script(&json!({"kind":"style","settings":{},"site":"news.example","cosmetic":stored})).unwrap();
        assert!(style.contains(".promo{display:none!important}"));
        let pick = page_script(&json!({"kind":"pick","label":"Zap \"it\""})).unwrap();
        assert!(pick.starts_with("new Promise(") && pick.contains(r#""Zap \"it\"""#));
    }

    #[test]
    fn address_rules_anchor_to_a_host_and_become_webkit_filters() {
        let list = "[Adblock Plus 2.0]\n||ads.example.com^\n||example.com/ads/*$image,third-party\n||cdn.example.org^*banner|\n||tracker.example/pixel?id=\n||exempt.example/ads/\n@@||exempt.example/ads/ok.js\n||a.example/x$domain=b.example\n||a.example/x$~third-party\n||a.example:8080/x\n||bad host/x\n/generic/ads/\n||a.example/(x)\n";
        let rules = parse_patterns_up_to(list, 100);
        assert_eq!(rules, vec!["||example.com/ads/*$third-party", "||cdn.example.org^*banner|", "||tracker.example/pixel?id="]);
        assert_eq!(pattern_url_filter(&rules[0]), Some((r"^[a-z]+://([^/]+\.)?example\.com/ads/.*".to_string(), true)));
        assert_eq!(pattern_url_filter(&rules[1]), Some((r"^[a-z]+://([^/]+\.)?cdn\.example\.org[/:?&=].*banner$".to_string(), false)));
        assert_eq!(pattern_url_filter(&rules[2]).unwrap().0, r"^[a-z]+://([^/]+\.)?tracker\.example/pixel\?id=");
        assert!(pattern_url_filter("||nohost").is_none() && pattern_url_filter("example.com/x").is_none());
    }

    #[test]
    fn page_scripts_embed_values_as_json() {
        let script = page_script(&json!({"kind":"findCount","query":"a\"b</script>"})).unwrap();
        assert!(script.contains(r#""a\"b</script>""#));
        let style = page_script(&json!({"kind":"style","settings":{"filter":"dark","hide":[".ad","bad{"]},"cookieBanners":true})).unwrap();
        assert!(style.contains(".ad{display:none!important}") && !style.contains("bad{{") && style.contains("onetrust"));
        assert!(page_script(&json!({"kind":"unknown"})).is_none());
        assert!(page_script(&json!({"kind":"deAmp"})).unwrap().contains("link[rel~=canonical]"));
    }

    #[test]
    fn shortcut_bindings_need_ordered_modifiers() {
        assert!(valid_binding("cmd+k"));
        assert!(valid_binding("ctrl+shift+tab"));
        assert!(valid_binding("f12"));
        assert!(!valid_binding("k"));
        assert!(!valid_binding("cmd+ctrl+k"));
        assert!(!valid_binding("hyper+k"));
    }
}
