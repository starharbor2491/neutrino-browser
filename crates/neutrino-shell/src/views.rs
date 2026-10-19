// SPDX-License-Identifier: MPL-2.0
//! Views for the shared browser features in `features.rs`.
use crate::features::{self, ACTIONS, FOLDER_COLORS, WEB_PANEL_SITES};
use crate::render::{host, icon, readable, segments, site, style, tab_row, tab_visible};
use crate::state::{array, flag, text, Shell};
use maud::{html, Markup};
use serde_json::{json, Value};

fn prefs(s: &Shell) -> &Value {
    &s.snapshot["preferences"]
}
fn profile_items<'a>(s: &'a Shell, key: &str) -> Vec<&'a Value> {
    array(&prefs(s)[key]).iter().filter(|v| v["profileID"] == s.snapshot["session"]["profileID"]).collect()
}
fn ids(s: &Shell, key: &str) -> Vec<String> {
    array(&s.snapshot[key]).iter().filter_map(Value::as_str).map(str::to_string).collect()
}
pub fn audible(s: &Shell, id: &str) -> bool {
    ids(s, "audible").iter().any(|v| v == id)
}
pub fn sleeping(s: &Shell, id: &str) -> bool {
    ids(s, "sleeping").iter().any(|v| v == id)
}
pub fn title(t: &Value) -> &str {
    let custom = text(t, "customTitle");
    if !custom.is_empty() {
        custom
    } else if text(t, "url").is_empty() {
        "Extension pages"
    } else {
        text(t, "title")
    }
}
/// A setting switch that sends a typed preference.
pub fn setting_toggle(label: &str, detail: &str, key: &str, value: bool) -> Markup {
    html! {button class="toggle-row" data-op="setting" data-key=(key) data-value=((!value).to_string()) data-type="bool" role="switch" aria-checked=(value.to_string()) {span {strong{(label)}@if !detail.is_empty(){small{(detail)}}} span class=(if value{"switch on"}else{"switch"}) {span{}}}}
}
/// A switch for a built-in feature module, shown where its settings live.
pub fn module_toggle(s: &Shell, key: &str, label: &str, detail: &str) -> Markup {
    let value = features::on(s, key);
    html! {button class="toggle-row" data-op="native" data-action="toggleModule" data-id=(format!("org.neutrino.{key}")) role="switch" aria-checked=(value.to_string()) {span {strong{(label)}@if !detail.is_empty(){small{(detail)}}} span class=(if value{"switch on"}else{"switch"}) {span{}}}}
}
fn choice(key: &str, current: i64, items: &[(i64, &str)]) -> Markup {
    let index = items.iter().position(|(v, _)| *v == current);
    html! {div class="segments" role="group" style=(format!("--count:{};--index:{}",items.len(),index.unwrap_or(0))) data-selected=(index.is_some().to_string()){@for (value,label) in items{button class=(if *value==current{"selected"}else{""}) data-op="setting" data-key=(key) data-value=(value) data-type="number" aria-pressed=((*value==current).to_string()){(label)}}}}
}

/// Speaker button on tabs that play sound or are muted.
pub fn tab_audio(s: &Shell, t: &Value) -> Markup {
    let id = text(t, "id");
    let muted = flag(t, "muted");
    html! {@if muted || audible(s, id) {button class=(if muted {"tab-audio muted"} else {"tab-audio"}) data-op="tab-action" data-id=(id) data-value="mute" title=(if muted {"Unmute tab"} else {"Mute tab"}) aria-label=(if muted {"Unmute tab"} else {"Mute tab"}) aria-pressed=(muted.to_string()){(icon(if muted {"muted"} else {"volume"}))}}}
}

/// Arc's Favorites: sites shared by every Space in this Profile.
pub fn favorites(s: &Shell) -> Markup {
    let list = profile_items(s, "favorites");
    let active = &s.active()["favoriteID"];
    html! {@if !list.is_empty() && !s.private() {div class="favorites-grid" aria-label="Favorites" {
        @for f in list {
            @let selected = !active.is_null() && *active == f["id"];
            div class=(if selected {"favorite-tile active"} else {"favorite-tile"}) data-favorite=(text(f,"id")) {
                button class="tab-select" data-op="favorite" data-value="open" data-id=(text(f,"id")) title=(text(f,"title")) aria-label=(text(f,"title")) aria-current=[selected.then_some("page")]{(site(f))}
                button class="tab-menu" data-op="menu" data-value=(format!("favorite:{}",text(f,"id"))) aria-label=(format!("Options for {}",text(f,"title"))){(icon("more"))}
            }
        }
    }}}
}

/// Opera's tab islands: a page and the tabs opened from it share one island.
pub fn islands(s: &Shell, tabs: &[&Value], preview: bool) -> Markup {
    let root = |t: &Value| {
        let mut current = t.clone();
        for _ in 0..8 {
            match s.tabs().iter().find(|x| x["id"] == current["parentID"]) {
                Some(parent) => current = parent.clone(),
                None => break,
            }
        }
        text(&current, "id").to_string()
    };
    let mut groups: Vec<(String, Vec<&Value>)> = vec![];
    for t in tabs {
        let key = root(t);
        match groups.iter_mut().find(|g| g.0 == key) {
            Some(group) => group.1.push(t),
            None => groups.push((key, vec![t])),
        }
    }
    html! {@for (index, (_, members)) in groups.iter().enumerate() {
        @if members.len() > 1 {div class="tab-island" data-tone=(index % 5) role="group" aria-label="Tab island"{@for t in members {(tab_row(t, s, preview))}}}
        @else {@for t in members {(tab_row(t, s, preview))}}
    }}
}

/// Vivaldi's two-level stacks: the active stack's tabs in a second row.
pub fn stack_row(s: &Shell, preview: bool) -> Markup {
    let folder = text(s.active(), "folderID");
    html! {@if !folder.is_empty() {div class="stack-row" role="group" aria-label="Tab stack"{
        @for t in s.tabs().iter().filter(|t| text(t,"folderID")==folder && tab_visible(t,s)) {(tab_row(t, s, preview))}
    }}}
}

/// Safari-style find bar between the toolbar and the page.
pub fn find_bar(s: &Shell) -> Markup {
    let count = s.snapshot["findResult"]["count"].as_u64().unwrap_or(0);
    let known = text(&s.snapshot["findResult"], "query") == s.find_query;
    html! {@if s.find_open {form class="find-bar" data-form="find" role="search" aria-label="Find on page"{
        (icon("search"))
        input id="find-input" name="find" type="text" value=(s.find_query.as_str()) placeholder="Find on page" autocomplete="off" spellcheck="false" aria-label="Find on page" data-find="true";
        span class="find-count" role="status"{@if !s.find_query.is_empty() && known {(if count == 0 {"No matches".to_string()} else {format!("{} of {}", s.find_index.clamp(1, count as usize), count)})}}
        button type="button" class="icon-button" data-op="find-step" data-value="-1" title="Previous match (⇧⌘G)" aria-label="Previous match" disabled[s.find_query.is_empty() || count == 0]{(icon("back"))}
        button type="button" class="icon-button" data-op="find-step" data-value="1" title="Next match (⌘G)" aria-label="Next match" disabled[s.find_query.is_empty() || count == 0]{(icon("forward"))}
        button type="button" class="button quiet" data-op="find-close"{"Done"}
    }}}
}

pub fn suggestions_menu(s: &Shell) -> Markup {
    let list = features::suggestions(s);
    html! {
        div class="suggest-list" role="listbox" aria-label="Suggestions"{
            button class=(if s.suggest_index == 0 {"suggest-item selected"} else {"suggest-item"}) data-op="suggest-accept" data-index="-1" role="option" aria-selected=((s.suggest_index==0).to_string()){
                span class="result-glyph"{(icon(if s.address_query.contains('.') && !s.address_query.contains(' ') {"globe"} else {"search"}))}
                span class="result-text"{strong{(s.address_query.as_str())}small{(if s.address_query.contains('.') && !s.address_query.contains(' ') {"Open address"} else {"Search"})}}
            }
            @for (i, item) in list.iter().enumerate() {
                button class=(if s.suggest_index == i + 1 {"suggest-item selected"} else {"suggest-item"}) data-op="suggest-accept" data-index=(i) role="option" aria-selected=((s.suggest_index==i+1).to_string()){
                    (site(item))
                    span class="result-text"{strong{(if text(item,"title").is_empty() {host(text(item,"url"))} else {text(item,"title").to_string()})}small{(readable(text(item,"url")))}}
                    span class="result-kind"{(match text(item,"kind"){"tab"=>"Switch to tab","bookmark"=>"Bookmark",_=>"History"})}
                }
            }
        }
    }
}

/// Site information from the address field's lock or globe.
pub fn site_menu(s: &Shell) -> Markup {
    let url = text(s.active(), "url");
    let site = host(url);
    let settings = &prefs(s)["siteSettings"][site.as_str()];
    let secure = url.starts_with("https://");
    let blocking = prefs(s)["blockTrackers"].as_bool().unwrap_or(true);
    let shields = blocking && !crate::render::shields_lowered(s);
    let zoom = (s.snapshot["zoom"].as_f64().unwrap_or(1.) * 100.).round();
    let chromium = text(s.active(), "engineID") != "webkit";
    let hidden = array(&settings["hide"]).len();
    html! {
        div class="site-info"{
            strong{(site)}
            p class=(if secure {"site-secure"} else {"site-insecure"}){(icon(if secure {"lock"} else {"globe"}))(if secure {"Connection is secure"} else {"Connection is not secure. Don’t enter passwords or payment details."})}
        }
        @if !s.private() {
            @if blocking {button class="toggle-row" data-op="shields-site" role="switch" aria-checked=(shields.to_string()){span{strong{"Block trackers and ads"}small{(if shields {"On for this site"} else {"Off for this site"})}}span class=(if shields{"switch on"}else{"switch"}){span{}}}}
            (site_toggle("JavaScript", "Turn off to stop scripts on this site.", "blockScripts", !flag(settings, "blockScripts")))
            (site_toggle("Pop-ups", "Allow this site to open windows.", "allowPopups", flag(settings, "allowPopups")))
            (site_toggle("Sound", "Turn off to mute this site in every tab.", "muted", !flag(settings, "muted")))
            @if features::on(s, "forget-sites") {(site_toggle("Forget me when I close this site", "Clear its cookies and storage when its last tab closes.", "forget", !flag(settings, "forget")))}
            @for (key, label) in [("camera", "Camera"), ("microphone", "Microphone")] {
                div class="site-permission"{span{(label)}(segments("site-setting", key, if text(settings,key).is_empty() {"ask"} else {text(settings,key)}, &[("ask","Ask"),("allow","Allow"),("block","Block")]))}
            }
            @if chromium {p class="field-help"{"Chromium tabs ask for camera and microphone with Chrome’s own prompt."}}
            div class="menu-separator"{}
            @if zoom != 100. {button class="menu-item" data-op="zoom-step" data-value="0"{(icon("search"))span{"Reset zoom ("(zoom)"%)"}}}
            button class="menu-item" data-op="page-command" data-value="pick-element"{(icon("focus"))span{"Block an element"}}
            @if hidden > 0 {button class="menu-item" data-op="site-setting" data-key="hide" data-value=""{(icon("undo"))span{"Show "(hidden)(if hidden == 1 {" hidden element"} else {" hidden elements"})}}}
            button class="menu-item" data-op="site-data" data-value="remove" data-host=(site){(icon("trash"))span{"Clear data for this site"}}
            button class="menu-item" data-op="screen" data-value="settings" data-section="privacy"{(icon("settings"))span{"Privacy settings"}}
        }
    }
}
fn site_toggle(label: &str, detail: &str, key: &str, on: bool) -> Markup {
    let value = if key == "allowPopups" { on } else { !on };
    html! {button class="toggle-row" data-op="site-setting" data-key=(key) data-value=((!value).to_string()) data-type="bool" role="switch" aria-checked=(on.to_string()){span{strong{(label)}small{(detail)}}span class=(if on{"switch on"}else{"switch"}){span{}}}}
}

pub fn page_menu(s: &Shell) -> Markup {
    let blank = text(s.active(), "url").is_empty();
    let enabled = |c: &str| array(&s.snapshot["modules"]).iter().any(|m| flag(m, "enabled") && text(m, "capability") == c);
    let gx = style(s) == "gx";
    let arc = style(s) == "arc";
    let zoom = (s.snapshot["zoom"].as_f64().unwrap_or(1.) * 100.).round();
    html! {
        div class="menu-group"{
            button class="menu-item" data-op="find-open" disabled[blank]{(icon("search"))span{"Find on page"}kbd{"⌘F"}}
            div class="menu-zoom" role="group" aria-label="Zoom"{span{"Zoom"}button data-op="zoom-step" data-value="-1" disabled[blank] aria-label="Zoom out"{"−"}button data-op="zoom-step" data-value="0" disabled[blank] title="Reset zoom"{(zoom)"%"}button data-op="zoom-step" data-value="1" disabled[blank] aria-label="Zoom in"{"+"}}
        }
        div class="menu-separator"{}
        div class="menu-group"{
            button class="menu-item" data-op="menu" data-value="split-choose" disabled[blank]{(icon("split"))span{"Split view"}}
            @if enabled("reader"){button class="menu-item" data-op="reader" disabled[blank]{(icon("reader"))span{"Reader view"}}}
            button class="menu-item" data-op="page-command" data-value="pip" disabled[blank]{(icon("pip"))span{"Picture in picture"}}
            @if features::on(s, "page-styles") {button class="menu-item" data-op="menu" data-value="page-style" disabled[blank]{(icon("appearance"))span{(if gx {"Page shaders"} else {"Page style"})}}}
            @if features::on(s, "boosts") {button class="menu-item" data-op="menu" data-value="boost" disabled[blank || s.private()]{(icon("edit"))span{(if arc {"Boost this site"} else {"Site CSS"})}}
            button class="menu-item" data-op="page-command" data-value="pick-element" disabled[blank || s.private()]{(icon("focus"))span{(if arc {"Zap an element"} else {"Hide an element"})}}}
            @if enabled("focusMode"){button class="menu-item" data-op="native" data-action="toggleFocus"{(icon("focus"))span{"Focus mode"}}}
        }
        div class="menu-separator"{}
        div class="menu-group"{
            @if features::on(s, "reading-list") {button class="menu-item" data-op="reading" data-value="add" disabled[blank || s.private()]{(icon("book"))span{"Add to Reading List"}kbd{"⇧⌘D"}}}
            @if enabled("screenshot"){button class="menu-item" data-op="menu" data-value="capture" disabled[blank]{(icon("camera"))span{"Capture"}kbd{"⇧⌘S"}}}
            @if enabled("notes"){button class="menu-item" data-op="panel" data-value="notes"{(icon("edit"))span{"Notes beside page"}}}
            button class="menu-item" data-op="summarize" disabled[blank]{(icon("spark"))span{"Summarize page"}}
            @if features::on(s, "feeds") && !text(&s.snapshot, "pageFeed").is_empty() && !s.private() {button class="menu-item" data-op="feed" data-value="subscribe-page"{(icon("feed"))span{"Subscribe to this site’s feed"}}}
            @if features::on(s, "autofill") && !array(&s.snapshot["cards"]).is_empty() {button class="menu-item" data-op="menu" data-value="fill-card" disabled[blank]{(icon("key"))span{"Fill card"}}}
            @if features::on(s, "autofill") && (!profile_items(s, "addresses").is_empty() || !array(&prefs(s)["addresses"]).is_empty()) {button class="menu-item" data-op="menu" data-value="fill-address" disabled[blank]{(icon("user"))span{"Fill address"}}}
        }
        div class="menu-separator"{}
        div class="menu-group"{
            button class="menu-item" data-op="page-command" data-value="copy-url" disabled[blank]{(icon("copy"))span{"Copy address"}kbd{"⇧⌘C"}}
            button class="menu-item" data-op="page-command" data-value="share" disabled[blank]{(icon("external"))span{"Share…"}}
            button class="menu-item" data-op="page-command" data-value="print" disabled[blank]{(icon("print"))span{"Print…"}kbd{"⌘P"}}
            button class="menu-item" data-op="page-command" data-value="save-pdf" disabled[blank]{(icon("download"))span{"Save as PDF…"}}
            button class="menu-item" data-op="page-command" data-value="save-page" disabled[blank]{(icon("download"))span{"Save page as…"}kbd{"⌘S"}}
            button class="menu-item" data-op="page-command" data-value="view-source" disabled[blank]{(icon("code"))span{"View source"}kbd{"⌥⌘U"}}
            button class="menu-item" data-op="page-command" data-value="dev-tools" disabled[blank]{(icon("terminal"))span{"Developer tools"}kbd{"⌥⌘I"}}
        }
    }
}

/// The browser menu, grouped so related commands sit together.
pub fn browser_menu(s: &Shell) -> Markup {
    let gx = style(s) == "gx";
    html! {
        div class="menu-group"{
            button class="menu-item" data-op="newTab"{(icon("plus"))span{"New tab"}kbd{"⌘T"}}
            button class="menu-item" data-op="newWindow"{(icon("window"))span{"New window"}kbd{"⌘N"}}
            button class="menu-item" data-op="privateWindow"{(icon("shield"))span{"New private window"}kbd{"⇧⌘N"}}
        }
        div class="menu-separator"{}
        div class="menu-group"{
            button class="menu-item" data-op="screen" data-value="library" data-section="history"{(icon("history"))span{"History"}kbd{"⌘Y"}}
            button class="menu-item" data-op="menu" data-value="recently-closed" disabled[array(&s.snapshot["closedTabs"]).is_empty()]{(icon("undo"))span{"Recently closed"}}
            button class="menu-item" data-op="screen" data-value="library" data-section="bookmarks"{(icon("bookmark"))span{"Bookmarks"}}
            button class="menu-item" data-op="screen" data-value="library" data-section="downloads"{(icon("download"))span{"Downloads"}}
            @if features::on(s, "reading-list") {button class="menu-item" data-op="screen" data-value="library" data-section="reading"{(icon("book"))span{"Reading List"}}}
        }
        div class="menu-separator"{}
        div class="menu-group"{
            button class="menu-item" data-op="screen" data-value="extensions"{(icon("plug"))span{"Extensions"}}
            button class="menu-item" data-op="screen" data-value="settings" data-section="performance"{(icon("activity"))span{"Task manager"}}
            button class="menu-item" data-op="menu" data-value="clear-data"{(icon("trash"))span{"Clear browsing data…"}}
            @if gx && features::on(s, "panic") {button class="menu-item" data-op="page-command" data-value="panic"{(icon("shield"))span{"Panic button"}kbd{"⌃⌥⌘P"}}}
        }
        div class="menu-separator"{}
        div class="menu-group"{
            button class="menu-item" data-op="screen" data-value="editor"{(icon("appearance"))span{"Customize"}}
            button class="menu-item" data-op="screen" data-value="modules"{(icon("grid"))span{"Modules"}}
            button class="menu-item" data-op="screen" data-value="settings"{(icon("settings"))span{"Settings"}kbd{"⌘,"}}
        }
    }
}

pub fn tab_menu(s: &Shell, t: &Value) -> Markup {
    let id = text(t, "id");
    let has_page = !text(t, "url").is_empty();
    let active = t["id"] == s.active()["id"];
    let muted = flag(t, "muted");
    let pinned_away = flag(t, "pinned") && !text(t, "pinnedURL").is_empty() && text(t, "pinnedURL") != text(t, "url");
    html! {
        div class="menu-group"{
            button class="menu-item" data-op="tab-action" data-id=(id) data-value="new-right"{(icon("plus"))span{(if crate::render::horizontal(s) {"New tab to the right"} else {"New tab below"})}}
            button class="menu-item" data-op="tab-action" data-id=(id) data-value="reload" disabled[!has_page]{(icon("reload"))span{"Reload"}}
            button class="menu-item" data-op="duplicateTab" data-id=(id){(icon("copy"))span{"Duplicate"}}
            button class="menu-item" data-op="pinTab" data-id=(id){(icon("pin"))span{(if flag(t,"pinned"){"Unpin"}else{"Pin"})}}
            @if pinned_away {button class="menu-item" data-op="tab-action" data-id=(id) data-value="reset-pinned"{(icon("home"))span{"Back to pinned page"}}}
            button class="menu-item" data-op="tab-action" data-id=(id) data-value="mute"{(icon(if muted {"volume"} else {"muted"}))span{(if muted {"Unmute tab"} else {"Mute tab"})}}
            @if !active && has_page && features::on(s, "tab-sleep") {button class="menu-item" data-op="tab-action" data-id=(id) data-value="sleep" disabled[sleeping(s,id)]{(icon("moon"))span{(if sleeping(s,id){"Sleeping"}else{"Put to sleep"})}}}
            button class="menu-item" data-op="tab-action" data-id=(id) data-value="rename"{(icon("edit"))span{"Rename"}}
        }
        div class="menu-separator"{}
        div class="menu-group"{
            button class="menu-item" data-op="tab-action" data-id=(id) data-value="copy" disabled[!has_page]{(icon("copy"))span{"Copy link"}}
            button class="menu-item" data-op="tab-action" data-id=(id) data-value="bookmark" disabled[!has_page || s.private()]{(icon("bookmark"))span{"Add to bookmarks"}}
            @if style(s) == "arc" && features::on(s, "favorites") {button class="menu-item" data-op="tab-action" data-id=(id) data-value="favorite" disabled[!has_page || s.private()]{(icon("star"))span{"Add to Favorites"}}}
            @if !active && has_page {button class="menu-item" data-op="tab-action" data-id=(id) data-value="split"{(icon("split"))span{"Split with current tab"}}}
            @if !s.private() && s.tabs().len() > 1 {button class="menu-item" data-op="tab-action" data-id=(id) data-value="new-window"{(icon("window"))span{"Move to new window"}}}
        }
        div class="menu-separator"{}
        div class="menu-group"{
            button class="menu-item" data-op="closeTab" data-id=(id){(icon("close"))span{"Close"}kbd{"⌘W"}}
            button class="menu-item" data-op="tab-action" data-id=(id) data-value="close-others"{(icon("close"))span{"Close other tabs"}}
            button class="menu-item" data-op="tab-action" data-id=(id) data-value="close-right"{(icon("close"))span{(if crate::render::horizontal(s) {"Close tabs to the right"} else {"Close tabs below"})}}
        }
    }
}

pub fn menus(s: &Shell, id: &str) -> Option<Markup> {
    let m = s.menu.as_str();
    Some(match m {
        "suggest" => suggestions_menu(s),
        "site" => site_menu(s),
        "page" => page_menu(s),
        "browser" => browser_menu(s),
        "recently-closed" => html! {div class="menu-label"{"Recently closed"}@for (i, t) in array(&s.snapshot["closedTabs"]).iter().enumerate().take(10) {button class="menu-item" data-op="reopen-closed" data-index=(i){(site(t))span{(if text(t,"title").is_empty(){host(text(t,"url"))}else{text(t,"title").to_string()})}@if i == 0 {kbd{"⇧⌘T"}}}}},
        "capture" => html! {
            button class="menu-item" data-op="capture-mode" data-value="area"{(icon("focus"))span{"Select an area…"}}
            button class="menu-item" data-op="capture-mode" data-value="visible"{(icon("camera"))span{"Visible part"}}
            button class="menu-item" data-op="capture-mode" data-value="full"{(icon("download"))span{"Full page"}}
            button class="menu-item" data-op="capture-mode" data-value="copy"{(icon("copy"))span{"Copy visible part"}}
        },
        "page-style" => {
            let site = host(text(s.active(), "url"));
            let current = text(&prefs(s)["siteSettings"][site.as_str()], "filter");
            html! {div class="menu-label"{(site)}@for (value, label) in [("", "Original"), ("dark", "Force dark"), ("grayscale", "Grayscale"), ("sepia", "Sepia"), ("contrast", "High contrast"), ("invert", "Invert colors"), ("noimages", "Hide images")] {
                button class="menu-item" data-op="site-setting" data-key="filter" data-value=(value) aria-pressed=((current==value).to_string()){(icon(if current==value {"check"} else {"appearance"}))span{(label)}}
            }}
        }
        "boost" => {
            let site = host(text(s.active(), "url"));
            let settings = &prefs(s)["siteSettings"][site.as_str()];
            html! {form class="boost-form" data-form="boost"{
                p class="field-help"{"Styles apply to "(site)" in every tab, after each page loads."}
                label class="field"{span{"Hide elements (CSS selectors, one per line)"}textarea name="hide" rows="3" maxlength="4000" spellcheck="false" placeholder=".cookie-banner\n#sidebar-ads"{(array(&settings["hide"]).iter().filter_map(Value::as_str).collect::<Vec<_>>().join("\n"))}}
                label class="field"{span{"Color"}input type="range" name="hue" min="0" max="359" step="1" value=(settings["hue"].as_i64().unwrap_or(0)) aria-label="Page hue";}
                label class="field"{span{"Custom CSS"}textarea name="css" rows="5" maxlength="20000" spellcheck="false" placeholder="body { font-family: Georgia, serif; }"{(text(settings,"css"))}}
                label class="field"{span{"Custom JavaScript"}textarea name="js" rows="4" maxlength="20000" spellcheck="false" placeholder="document.querySelector('.promo')?.remove();"{(text(settings,"js"))}}
                p class="field-help"{"JavaScript runs after each page on this site loads, separate from the site’s own scripts."}
                div class="button-row"{button class="button primary" type="submit"{"Apply"}}
            }}
        }
        "clear-data" => html! {form class="clear-form" data-form="clear-data"{
            label class="field"{span{"Time range"}select name="range"{option value="hour"{"Last hour"}option value="day"{"Last 24 hours"}option value="week"{"Last 7 days"}option value="month"{"Last 4 weeks"}option value="all" selected{"All time"}}}
            @for (key, label, detail, on) in [("history","Browsing history","Pages you visited",true),("cookies","Cookies and site data","Signs you out of most sites",true),("cache","Cached images and files","Pages may load slower next time",true),("downloads","Download list","Files stay on disk",false)] {
                label class="check-row"{input type="checkbox" name="items" value=(key) checked[on];span{strong{(label)}small{(detail)}}}
            }
            p class="field-help"{"Chromium tabs clear cookies and cache for all time, whatever the range."}
            div class="button-row"{button class="button" type="button" data-op="escape"{"Cancel"}button class="button primary" type="submit"{"Clear data"}}
        }},
        m if m.starts_with("nav-history:") => {
            let list = &s.snapshot["navigationList"];
            html! {div class="menu-label"{(if m.ends_with("back") {"Back to"} else {"Forward to"})}
                @if text(list,"direction") != &m[12..] {p class="field-help"{"Loading…"}}
                @else {@for item in array(&list["items"]).iter().take(15) {button class="menu-item" data-op="go-history" data-offset=(item["offset"].as_i64().unwrap_or(0)){(site(item))span{(if text(item,"title").is_empty(){host(text(item,"url"))}else{text(item,"title").to_string()})}}}
                    @if array(&list["items"]).is_empty() {p class="field-help"{"No other pages in this tab."}}}
            }
        }
        m if m.starts_with("rename-tab:") => html! {label class="field"{span{"Tab name"}input id="name-input" data-name="true" value=(s.name.as_str()) placeholder="Leave empty to use the page title" maxlength="120" autocomplete="off";}button class="button primary" data-op="rename-tab" data-id=(id){"Save"}},
        "save-session" => html! {label class="field"{span{"Session name"}input id="name-input" data-name="true" value=(s.name.as_str()) placeholder="Research, Trip planning…" maxlength="80" autocomplete="off";}button class="button primary" data-op="session" data-value="save" disabled[s.name.trim().is_empty()]{"Save "(s.tabs().iter().filter(|t|!text(t,"url").is_empty()).count())" tabs"}},
        "add-panel" => html! {
            div class="menu-label"{"Popular"}
            div class="panel-presets"{@for (title, url) in WEB_PANEL_SITES {button class="panel-preset" data-op="web-panel" data-value="preset" data-url=(url) title=(title){(site(&json!({"url":url})))span{(title)}}}}
            label class="field"{span{"Or any site"}input id="name-input" data-name="true" value=(s.name.as_str()) placeholder="web.whatsapp.com" maxlength="2000" autocomplete="off" spellcheck="false";}
            button class="button primary" data-op="web-panel" data-value="add" disabled[s.name.trim().is_empty()]{"Add panel"}
        },
        m if m.starts_with("web-panel:") => html! {
            button class="menu-item" data-op="web-panel" data-value="reload" data-id=(id){(icon("reload"))span{"Reload panel"}}
            button class="menu-item" data-op="web-panel" data-value="tab" data-id=(id){(icon("external"))span{"Open as tab"}}
            button class="menu-item" data-op="web-panel" data-value="remove" data-id=(id){(icon("trash"))span{"Remove panel"}}
        },
        m if m.starts_with("favorite:") => html! {button class="menu-item" data-op="favorite" data-value="remove" data-id=(id){(icon("trash"))span{"Remove from Favorites"}}},
        "space-style" => {
            let space = array(&s.snapshot["spaces"]).iter().find(|v| v["id"] == s.snapshot["session"]["spaceID"]).cloned().unwrap_or(Value::Null);
            html! {form class="space-style" data-form="space-style"{
                label class="field"{span{"Icon"}input name="emoji" value=(text(&space,"emoji")) maxlength="8" placeholder="Letter or emoji" autocomplete="off";}
                div class="color-pair"{label class="field"{span{"Top color"}input type="color" name="from" value=(array(&space["gradient"]).first().and_then(Value::as_str).unwrap_or("#7c5cff"));}label class="field"{span{"Bottom color"}input type="color" name="to" value=(array(&space["gradient"]).get(1).and_then(Value::as_str).unwrap_or("#1f6feb"));}}
                div class="button-row"{button class="button" type="button" data-op="space-appearance" data-emoji="" {"Reset"}button class="button primary" type="submit"{"Apply"}}
            }}
        }
        m if m.starts_with("delete-space:") => html! {p{"Delete this Space? Its tabs and folders close. Bookmarks, history and sign-ins are kept."}button class="button danger" data-op="delete-space" data-id=(id){"Delete Space"}},
        m if m.starts_with("delete-profile:") => html! {p{"Delete this Profile? Its Spaces, tabs, cookies, passwords and history on this Mac are erased."}button class="button danger" data-op="delete-profile" data-id=(id){"Delete Profile"}},
        m if m.starts_with("edit-bookmark:") => {
            let b = array(&s.snapshot["bookmarkIndex"]).iter().chain(array(&s.snapshot["bookmarks"])).find(|b| text(b, "id") == id).cloned().unwrap_or(Value::Null);
            html! {form data-form="edit-bookmark" data-id=(id){
                label class="field"{span{"Name"}input name="title" value=(text(&b,"title")) maxlength="512";}
                label class="field"{span{"Address"}input name="url" value=(text(&b,"url")) maxlength="8192" spellcheck="false";}
                label class="field"{span{"Folder"}input name="folder" value=(text(&b,"folder")) list="bookmark-folders" maxlength="160" placeholder="None, or Work/Projects";}
                datalist id="bookmark-folders"{@for f in bookmark_folders(s) {option value=(f);}option value="Speed Dial";option value="Bookmarks bar";}
                div class="button-row"{button class="button" type="button" data-op="native" data-action="removeBookmark" data-id=(id){"Delete"}button class="button primary" type="submit"{"Save"}}
            }}
        }
        // Chrome's tab search: every open tab in this Space, filtered as you type.
        "tab-search" => {
            let query = s.name.to_lowercase();
            let tabs: Vec<&Value> = s.tabs().iter().filter(|t| query.is_empty() || title(t).to_lowercase().contains(&query) || text(t, "url").to_lowercase().contains(&query)).collect();
            html! {
                label class="field"{span{"Search open tabs"}input id="name-input" data-name="true" value=(s.name.as_str()) placeholder="Title or address" maxlength="200" autocomplete="off";}
                @if tabs.is_empty() {p class="field-help"{"No open tab matches."}}
                @for t in tabs.iter().take(60) {button class="menu-item" data-op="selectTab" data-id=(text(t,"id")){(site(t))span{(title(t))@if !text(t,"url").is_empty() {small{(host(text(t,"url")))}}}}}
            }
        }
        m if m.starts_with("bm-overflow:") => {
            let first: usize = m[12..].parse().unwrap_or(0);
            let (loose, folders) = bar_entries(s);
            html! {
                @for b in loose.iter().skip(first) {(bar_entry(Some(b), None, "menu-item"))}
                @for f in folders.iter().skip(first.saturating_sub(loose.len())) {(bar_entry(None, Some(f), "menu-item"))}
            }
        }
        m if m.starts_with("bm-folder:") => {
            let folder = &m[10..];
            html! {
                @for f in folder_children(s, folder) {button class="menu-item" data-op="menu" data-value=(format!("bm-folder:{f}")){(icon("folder"))span{(folder_name(&f))}}}
                @for b in array(&s.snapshot["bookmarkIndex"]).iter().filter(|b| text(b,"folder")==folder).take(40) {button class="menu-item" data-op="navigate" data-value=(text(b,"url")){(site(b))span{(text(b,"title"))}}}
            }
        }
        "new-board" => html! {label class="field"{span{"Board name"}input id="name-input" data-name="true" value=(s.name.as_str()) placeholder="Moodboard, Trip, Research…" maxlength="80" autocomplete="off";}button class="button primary" data-op="board" data-value="create" disabled[s.name.trim().is_empty()]{"Create board"}},
        m if m.starts_with("board-note:") => html! {label class="field"{span{"Note"}input id="name-input" data-name="true" value=(s.name.as_str()) maxlength="2000" autocomplete="off";}button class="button primary" data-op="board" data-value="add-note" data-board=(id) disabled[s.name.trim().is_empty()]{"Add note"}},
        m if m.starts_with("board-add:") => html! {div class="menu-label"{"Add this page to"}@for b in profile_items(s, "boards") {button class="menu-item" data-op="board" data-value="add-page" data-board=(text(b,"id")){(icon("grid"))span{(text(b,"name"))}}}(crate::render::menu_item("New board…","menu","new-board","plus"))},
        "fill-card" => html! {div class="menu-label"{"Fill this page with"}@for c in array(&s.snapshot["cards"]) {button class="menu-item" data-op="card" data-value="fill" data-id=(text(c,"id")){(icon("key"))span{(text(c,"name"))" ····"(text(c,"last4"))}}}},
        "fill-address" => html! {div class="menu-label"{"Fill this page with"}@for a in array(&prefs(s)["addresses"]) {button class="menu-item" data-op="address-book" data-value="fill" data-id=(text(a,"id")){(icon("user"))span{(text(a,"name"))small{(text(a,"street"))}}}}},
        _ => return None,
    })
}

pub fn menu_title(m: &str) -> Option<&'static str> {
    Some(match m {
        "clear-data" => "Clear browsing data",
        "boost" => "Site styles",
        "add-panel" => "Add a panel",
        "save-session" => "Save session",
        "space-style" => "Space appearance",
        "new-board" => "New board",
        m if m.starts_with("rename-tab:") => "Rename tab",
        m if m.starts_with("edit-bookmark:") => "Edit bookmark",
        m if m.starts_with("board-note:") => "Add a note",
        m if m.starts_with("shortcut-conflict:") => "Shortcut in use",
        "tab-search" => "Search tabs",
        _ => return None,
    })
}

/// Folder paths directly inside `parent` ("" for the top level). Folders nest with "/".
fn folder_children(s: &Shell, parent: &str) -> Vec<String> {
    let mut out: Vec<String> = vec![];
    for f in bookmark_folders(s) {
        let rest = if parent.is_empty() { Some(f.as_str()) } else { f.strip_prefix(parent).and_then(|r| r.strip_prefix('/')) };
        if let Some(rest) = rest.filter(|r| !r.is_empty()) {
            let child = match rest.split_once('/') {
                Some((first, _)) if parent.is_empty() => first.to_string(),
                Some((first, _)) => format!("{parent}/{first}"),
                None if parent.is_empty() => rest.to_string(),
                None => format!("{parent}/{rest}"),
            };
            if !out.contains(&child) {
                out.push(child);
            }
        }
    }
    out
}
fn folder_name(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}
fn bookmark_folders(s: &Shell) -> Vec<String> {
    let mut out: Vec<String> = vec![];
    for b in array(&s.snapshot["bookmarkIndex"]) {
        let f = text(b, "folder");
        if !f.is_empty() && !out.iter().any(|x| x == f) {
            out.push(f.to_string());
        }
    }
    out
}

/// Chrome-style bookmarks bar: loose bookmarks, then folders as menus.
/// What the bookmarks bar holds, in order: loose bookmarks, then folders.
fn bar_entries(s: &Shell) -> (Vec<&Value>, Vec<String>) {
    let index = array(&s.snapshot["bookmarkIndex"]);
    let loose: Vec<&Value> = index.iter().filter(|b| ["", "Bookmarks bar"].contains(&text(b, "folder"))).take(60).collect();
    let folders: Vec<String> = folder_children(s, "").into_iter().filter(|f| f != "Bookmarks bar").collect();
    (loose, folders)
}
fn bar_entry(b: Option<&Value>, folder: Option<&String>, class: &str) -> Markup {
    html! {
        @if let Some(b) = b {button class=(class) data-op="navigate" data-value=(text(b,"url")) title=(text(b,"url")){(site(b))span{(text(b,"title"))}}}
        @if let Some(f) = folder {button class=(class) data-op="menu" data-value=(format!("bm-folder:{f}")){(icon("folder"))span{(folder_name(f))}}}
    }
}
pub fn bookmarks_bar(s: &Shell) -> Markup {
    let (loose, folders) = bar_entries(s);
    html! {nav class="bookmarks-bar" aria-label="Bookmarks bar"{
        @if loose.is_empty() && folders.is_empty() {span class="bar-empty"{"Press ⌘D to bookmark a page and it appears here."}button class="button quiet" data-op="importBookmarks"{"Import bookmarks"}}
        @else {
            div class="bar-items"{
                @for b in &loose {(bar_entry(Some(b), None, "bar-item"))}
                @for f in &folders {(bar_entry(None, Some(f), "bar-item"))}
            }
            // Shown by the interface script when items don't fit, as Chrome's and Vivaldi's » menus are.
            button class="bar-item bar-overflow" data-op="menu" data-value="bm-overflow:0" hidden aria-label="More bookmarks" title="More bookmarks"{"»"}
        }
    }}
}

/// Sites for the Speed Dial: its bookmark folder, if the person filled it.
pub fn speed_dial(s: &Shell) -> Vec<(String, String, String)> {
    if !features::on(s, "speed-dial") {
        return vec![];
    }
    array(&s.snapshot["bookmarkIndex"]).iter().filter(|b| text(b, "folder") == "Speed Dial").take(24).map(|b| (text(b, "title").to_string(), text(b, "url").to_string(), text(b, "id").to_string())).collect()
}

pub fn wallpaper_style(s: &Shell) -> String {
    if !features::on(s, "wallpapers") {
        return String::new();
    }
    let image = text(&s.snapshot, "wallpaper");
    if (image.starts_with("data:image/jpeg;base64,") || image.starts_with("data:image/png;base64,") || image.starts_with("data:image/svg+xml;base64,"))
        && image.len() < 4_000_000
        && !image.contains(['"', '\'', ')', '('])
        && prefs(s)["startPage"]["wallpaper"].as_bool().unwrap_or(true)
    {
        format!("--wallpaper:url({image})")
    } else {
        String::new()
    }
}
pub fn start_option(s: &Shell, key: &str) -> bool {
    prefs(s)["startPage"][key].as_bool().unwrap_or(true)
}

/// The start-page parts a style's new tab page actually has.
pub fn start_options(s: &Shell) -> Vec<(&'static str, &'static str)> {
    let mut out: Vec<(&str, &str)> = match style(s) {
        "arc" => vec![],
        "chrome" => vec![("search", "Search box"), ("sites", "Shortcuts")],
        "brave" => vec![("search", "Search box"), ("sites", "Top sites"), ("clock", "Clock"), ("stats", "Shields stats")],
        "vivaldi" | "gx" => vec![("search", "Search box"), ("sites", "Speed Dial"), ("clock", "Clock")],
        "safari" => vec![("sites", "Favorites and Frequently Visited"), ("stats", "Privacy Report"), ("reading", "Reading List")],
        _ => vec![("search", "Search box")],
    };
    if features::on(s, "wallpapers") {
        out.push(("wallpaper", "Background image"));
    }
    if !features::on(s, "reading-list") {
        out.retain(|o| o.0 != "reading");
    }
    out
}

/// A strip of panel buttons for web panels the person added.
pub fn web_panel_buttons(s: &Shell) -> Markup {
    if !features::on(s, "web-panels") {
        return html! {};
    }
    let open = s.visible_panel_key();
    html! {
        @for p in profile_items(s, "webPanels") {
            @let key = format!("web:{}", text(p, "id"));
            button class=(if open == key {"strip-button web-panel-button selected"} else {"strip-button web-panel-button"}) data-op="panel" data-value=(if open == key {String::new()} else {key.clone()}) data-tip=(text(p,"title")) aria-label=(text(p,"title")) aria-pressed=((open == key).to_string()) data-panel-id=(text(p,"id")){(site(p))}
        }
        @if !s.private() {button class="strip-button" data-op="menu" data-value="add-panel" data-tip="Add a panel" aria-label="Add a panel"{(icon("plus"))}}
    }
}
pub fn web_panel(s: &Shell, key: &str) -> Markup {
    let id = &key[4..];
    let panel = profile_items(s, "webPanels").into_iter().find(|p| text(p, "id") == id).cloned().unwrap_or(Value::Null);
    html! {aside class="workspace-panel web-panel" aria-label=(text(&panel,"title")) {
        header{(site(&panel))h2{(text(&panel,"title"))}button class="icon-button" data-op="menu" data-value=(format!("web-panel:{id}")) aria-label="Panel options"{(icon("more"))}button class="icon-button" data-op="panel" data-value="" aria-label="Close panel"{(icon("close"))}}
        div class="native-page web-panel-page" data-page=(id) data-panel="true"{}
    }}
}

/// Now playing: the tab that most recently made sound.
pub fn media_card(s: &Shell) -> Markup {
    if !features::on(s, "media-controls") {
        return html! {};
    }
    let media = &s.snapshot["media"];
    let id = text(media, "id");
    let Some(t) = s.tabs().iter().find(|t| text(t, "id") == id) else { return html! {} };
    let playing = flag(media, "playing");
    html! {div class="media-card" role="group" aria-label="Now playing"{
        button class="media-title" data-op="selectTab" data-id=(id) title="Go to tab"{(site(t))span{strong{(title(t))}small{(host(text(t,"url")))}}}
        div class="media-controls"{
            button class="icon-button" data-op="page-command" data-value="media" data-id=(id) aria-label=(if playing {"Pause"} else {"Play"}){(icon(if playing {"pause"} else {"play"}))}
            button class="icon-button" data-op="tab-action" data-value="mute" data-id=(id) aria-label=(if flag(t,"muted") {"Unmute"} else {"Mute"}){(icon(if flag(t,"muted") {"muted"} else {"volume"}))}
            button class="icon-button" data-op="page-command" data-value="pip" data-id=(id) aria-label="Picture in picture"{(icon("pip"))}
        }
    }}
}

pub fn capture_overlay(s: &Shell) -> Markup {
    let image = s.snapshot["pageBackdrops"][text(s.active(), "id")].as_str().unwrap_or("");
    html! {@if s.capture_select {div class="capture-overlay" data-capture="true" role="dialog" aria-label="Select an area to capture"{
        @if image.starts_with("data:image/png;base64,") {img class="capture-image" src=(image) alt="";}
        div class="capture-hint"{"Drag to select an area. Hold ⌥ to copy instead of saving. Esc cancels."}
        div class="capture-box" hidden{}
    }}}
}

pub fn break_overlay(s: &Shell) -> Markup {
    html! {@if flag(&s.snapshot, "breakMode") {div class="break-overlay" role="dialog" aria-label="Break mode"{
        div class="break-card"{(icon("pause"))h2{"Taking a break"}p{"Sound and video are paused and pages are hidden."}time class="break-clock" data-clock="true"{}button class="button primary" data-op="page-command" data-value="break"{"Resume browsing"}}
    }}}
}

fn day(seconds: f64) -> i64 {
    // Reference date 2001-01-01 is a Monday; days since then in UTC.
    // Days since 2001 fit in an i32, which avoids 64-bit float truncation in wasm builds.
    (seconds / 86_400.).floor().clamp(-1e6, 1e6) as i32 as i64
}
fn day_label(today: i64, value: i64) -> String {
    match today - value {
        0 => "Today".into(),
        1 => "Yesterday".into(),
        n if n < 7 => ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][value.rem_euclid(7) as usize].into(),
        n => format!("{n} days ago"),
    }
}

pub fn history(s: &Shell) -> Markup {
    let items = array(&s.snapshot["history"]);
    let now = s.snapshot["now"].as_f64().unwrap_or(0.);
    let today = day(now);
    let query = text(&s.snapshot, "historyQuery");
    // Each entry, with a day heading before the first entry of each day.
    let mut last = i64::MIN;
    let rows: Vec<(Option<String>, &Value)> = items
        .iter()
        .map(|h| {
            let d = day(h["visitedAt"].as_f64().unwrap_or(now));
            let heading = (d != last && now > 0.).then(|| day_label(today, d));
            last = d;
            (heading, h)
        })
        .collect();
    html! {
        div class="library-actions"{input class="library-search" type="search" data-library-query="history" value=(query) placeholder="Search history" maxlength="160" aria-label="Search history";span class="spacer"{}button class="button" data-op="menu" data-value="clear-data"{"Clear browsing data…"}}
        @if items.is_empty() {(crate::render::empty(if query.is_empty() {"No history yet"} else {"No matching pages"}, if query.is_empty() {"Pages you visit appear here. Private windows aren’t recorded."} else {"Try another word from the page title or address."}, "history"))}
        @for (heading, h) in rows {
            @if let Some(heading) = heading {h3 class="day-heading"{(heading)}}
            div class="list-row history-entry"{
                button class="bookmark-link" data-op="navigate" data-value=(text(h,"url")){(site(h))span{strong{(text(h,"title"))}small{(host(text(h,"url")))}}}
                button class="icon-button" data-op="native" data-action="removeHistory" data-id=(text(h,"id")) aria-label=(format!("Remove {} from history",text(h,"title"))){(icon("close"))}
            }
        }
    }
}

pub fn bookmarks(s: &Shell) -> Markup {
    let items = array(&s.snapshot["bookmarks"]);
    let query = text(&s.snapshot, "bookmarkQuery");
    let filter = s.library_filter.as_str();
    let folders = folder_children(s, filter);
    let index = array(&s.snapshot["bookmarkIndex"]);
    let shown: Vec<&Value> = if filter.is_empty() { items.iter().collect() } else { index.iter().filter(|b| text(b, "folder") == filter).collect() };
    let mut trail: Vec<String> = vec![];
    for part in filter.split('/').filter(|p| !p.is_empty()) {
        trail.push(match trail.last() { Some(last) => format!("{last}/{part}"), None => part.to_string() });
    }
    html! {
        div class="library-actions"{input class="library-search" type="search" data-library-query="bookmarks" value=(query) placeholder="Search bookmarks" maxlength="160" aria-label="Search bookmarks";span class="spacer"{}button class="button" data-op="importBookmarks"{"Import…"}button class="button" data-op="exportBookmarks"{"Export…"}}
        @if !folders.is_empty() || !filter.is_empty() {div class="filter-chips" role="group" aria-label="Folders"{
            button class=(if filter.is_empty(){"chip selected"}else{"chip"}) data-op="library-filter" data-value="" data-bookmark-folder=""{"All"}
            @for path in &trail {button class=(if filter==path {"chip selected"}else{"chip"}) data-op="library-filter" data-value=(path) data-bookmark-folder=(path){(folder_name(path))}}
            @for f in &folders {button class="chip" data-op="library-filter" data-value=(f) data-bookmark-folder=(f){(icon("folder"))(folder_name(f))}}
        }}
        @if items.is_empty() {div class="empty-state"{(icon("bookmark"))h3{(if query.is_empty(){"No bookmarks yet"}else{"No matching bookmarks"})}p{"Press ⌘D on any page to bookmark it, or bring bookmarks over from another browser."}@if query.is_empty(){button class="button primary" data-op="importBookmarks"{"Import bookmarks…"}}}}
        @for b in shown {div class="list-row" draggable=((!s.private()).to_string()) data-bookmark=(text(b,"id")){
            button class="bookmark-link" data-op="navigate" data-value=(text(b,"url")){(site(b))span{strong{(text(b,"title"))}small{(host(text(b,"url")))@if !text(b,"folder").is_empty(){" · "(text(b,"folder"))}}}}
            button class="icon-button" data-op="menu" data-value=(format!("edit-bookmark:{}",text(b,"id"))) aria-label=(format!("Edit {}",text(b,"title"))){(icon("edit"))}
            button class="icon-button" data-op="native" data-action="removeBookmark" data-id=(text(b,"id")) aria-label=(format!("Remove {}",text(b,"title"))){(icon("close"))}
        }}
    }
}

pub fn downloads(s: &Shell) -> Markup {
    let list = array(&s.snapshot["downloads"]);
    html! {
        @if list.iter().any(|d| flag(d,"complete") || flag(d,"ended")) {div class="library-actions"{span class="spacer"{}button class="button" data-op="native" data-action="downloadClear"{"Clear finished"}}}
        @if list.is_empty() {(crate::render::empty("No downloads","Files you download appear here.","download"))}
        @for d in list {div class="list-row"{(icon("download"))div{strong{(text(d,"name"))}small{(text(d,"status"))}
                @if !flag(d,"complete") && d["fraction"].is_number() && (flag(d,"canPause") || flag(d,"paused")) {progress class="download-progress" max="1" value=(d["fraction"].as_f64().unwrap_or(0.).clamp(0., 1.)) aria-label=(format!("{} progress", text(d,"name"))){}}}
            @if flag(d,"complete") {div class="button-row"{button class="button" data-op="native" data-action="downloadOpen" data-id=(text(d,"id")){"Open"}button class="button" data-op="native" data-action="downloadReveal" data-id=(text(d,"id")){"Show in Finder"}button class="icon-button" data-op="native" data-action="downloadRemove" data-id=(text(d,"id")) aria-label="Remove from list"{(icon("close"))}}}
            @else if flag(d,"ended") {button class="icon-button" data-op="native" data-action="downloadRemove" data-id=(text(d,"id")) aria-label="Remove from list"{(icon("close"))}}
            @else {div class="button-row"{
                @if flag(d,"canPause") {@if flag(d,"paused") {button class="button" data-op="native" data-action="downloadResume" data-id=(text(d,"id")){"Resume"}} @else {button class="button" data-op="native" data-action="downloadPause" data-id=(text(d,"id")){"Pause"}}}
                button class="button" data-op="native" data-action="downloadCancel" data-id=(text(d,"id")){"Cancel"}
            }}
        }}
    }
}

pub fn reading(s: &Shell) -> Markup {
    let filter = s.library_filter.as_str();
    let items: Vec<&Value> = profile_items(s, "readingList").into_iter().filter(|i| match filter { "unread" => !flag(i, "read"), "playlist" => flag(i, "media"), _ => true }).collect();
    html! {
        div class="filter-chips" role="group" aria-label="Show"{@for (value,label) in [("","All"),("unread","Unread"),("playlist","Playlist")] {button class=(if filter==value {"chip selected"}else{"chip"}) data-op="library-filter" data-value=(value){(label)}}span class="spacer"{}button class="button" data-op="reading" data-value="add" disabled[text(s.active(),"url").is_empty() || s.private()]{(icon("plus"))"Add current page"}}
        @if items.is_empty() {(crate::render::empty("Nothing to read yet","Save pages to read later with ⇧⌘D. Pages with video or music can go in your Playlist from the page menu.","book"))}
        @for i in items {div class=(if flag(i,"read") {"list-row read"} else {"list-row"}){
            button class="bookmark-link" data-op="navigate" data-value=(text(i,"url")){(site(i))span{strong{(text(i,"title"))}small{(host(text(i,"url")))@if flag(i,"media"){" · Playlist"}}}}
            button class="button quiet" data-op="reading" data-value=(if flag(i,"read"){"unread"}else{"read"}) data-id=(text(i,"id")){(if flag(i,"read"){"Mark unread"}else{"Mark read"})}
            button class="icon-button" data-op="reading" data-value="remove" data-id=(text(i,"id")) aria-label="Remove"{(icon("close"))}
        }}
    }
}

pub fn sessions(s: &Shell) -> Markup {
    let list = profile_items(s, "savedSessions");
    html! {
        div class="library-actions"{span class="spacer"{}button class="button" data-op="menu" data-value="save-session" disabled[s.private()]{(icon("plus"))"Save open tabs…"}}
        @if list.is_empty() {(crate::render::empty("No saved sessions","Save the tabs you have open as a named session, then reopen them all later.","folder"))}
        @for v in list {div class="list-row"{(icon("folder"))div{strong{(text(v,"name"))}small{(array(&v["tabs"]).len())" tabs · "(array(&v["tabs"]).iter().take(3).map(|t|host(text(t,"url"))).collect::<Vec<_>>().join(", "))}}
            div class="button-row"{button class="button" data-op="session" data-value="open" data-id=(text(v,"id")){"Open"}button class="icon-button" data-op="session" data-value="delete" data-id=(text(v,"id")) aria-label=(format!("Delete {}",text(v,"name"))){(icon("trash"))}}
        }}
    }
}

pub fn boards(s: &Shell) -> Markup {
    let list = profile_items(s, "boards");
    let selected = list.iter().find(|b| text(b, "id") == s.board).or(list.first()).copied();
    html! {
        div class="library-actions"{
            @for b in &list {button class=(if selected.is_some_and(|x| x["id"]==b["id"]) {"chip selected"} else {"chip"}) data-op="board-select" data-value=(text(b,"id")){(icon("grid"))(text(b,"name"))}}
            span class="spacer"{}button class="button" data-op="menu" data-value="new-board" disabled[s.private()]{(icon("plus"))"New board"}
        }
        @if let Some(b) = selected {
            @let board = text(b, "id");
            div class="board-actions"{button class="button" data-op="board" data-value="add-page" data-board=(board) disabled[text(s.active(),"url").is_empty()]{"Add current page"}button class="button" data-op="menu" data-value=(format!("board-note:{board}")){"Add note"}span class="spacer"{}button class="button quiet danger" data-op="board" data-value="delete" data-board=(board){"Delete board"}}
            div class="board-canvas" data-board=(board) aria-label=(format!("Board {}",text(b,"name"))){
                @for item in array(&b["items"]) {
                    div class=(format!("board-card {}",text(item,"kind"))) data-item=(text(item,"id")) style=(format!("left:{}px;top:{}px",item["x"].as_f64().unwrap_or(0.),item["y"].as_f64().unwrap_or(0.))) tabindex="0"{
                        @if text(item,"kind")=="link" {button class="board-link" data-op="navigate" data-value=(text(item,"url")){(site(item))span{strong{(text(item,"title"))}small{(host(text(item,"url")))}}}}
                        @else {p{(text(item,"text"))}}
                        button class="icon-button board-remove" data-op="board" data-value="remove" data-board=(board) data-item=(text(item,"id")) aria-label="Remove from board"{(icon("close"))}
                    }
                }
                @if array(&b["items"]).is_empty() {p class="board-empty"{"Add pages and notes, then drag them to arrange the board."}}
            }
        } @else {(crate::render::empty("No boards yet","Collect pages and notes on a board, and arrange them freely.","grid"))}
    }
}

pub fn source(s: &Shell) -> Markup {
    let source = &s.snapshot["source"];
    html! {div class="source-content"{
        @if text(source,"text").is_empty() {div class="resource-loading" role="status"{span class="loading-spinner"{}"Reading the page source…"}}
        @else {p class="field-help"{(readable(text(source,"url")))}pre class="source-text"{@for (n, line) in text(source,"text").lines().enumerate().take(20_000) {span class="source-line" data-line=(n+1){(line)"\n"}}}}
    }}
}

pub fn reader_style(s: &Shell) -> String {
    let r = &prefs(s)["readerStyle"];
    format!("--reader-size:{}px", r["size"].as_i64().unwrap_or(19).clamp(14, 28))
}
pub fn reader_controls(s: &Shell) -> Markup {
    let r = &prefs(s)["readerStyle"];
    let size = r["size"].as_i64().unwrap_or(19).clamp(14, 28);
    let theme = r["theme"].as_str().unwrap_or("auto");
    let font = r["font"].as_str().unwrap_or("serif");
    let with = |key: &str, value: Value| {
        let mut next = json!({"size":size,"theme":theme,"font":font});
        next[key] = value;
        next.to_string()
    };
    html! {div class="reader-controls" role="toolbar" aria-label="Reader"{
        button class="icon-button" data-op="setting" data-key="readerStyle" data-json=(with("size", json!((size - 1).max(14)))) aria-label="Smaller text" disabled[size<=14]{"A−"}
        button class="icon-button" data-op="setting" data-key="readerStyle" data-json=(with("size", json!((size + 1).min(28)))) aria-label="Larger text" disabled[size>=28]{"A+"}
        @for (value, label) in [("serif","Serif"),("sans","Sans")] {button class=(if font==value {"chip selected"} else {"chip"}) data-op="setting" data-key="readerStyle" data-json=(with("font", json!(value)))aria-pressed=((font==value).to_string()){(label)}}
        @for (value, label) in [("auto","Auto"),("light","Light"),("sepia","Sepia"),("dark","Dark")] {button class=(format!("reader-swatch {value}{}", if theme==value {" selected"} else {""})) data-op="setting" data-key="readerStyle" data-json=(with("theme", json!(value))) aria-label=(label) aria-pressed=((theme==value).to_string()) title=(label){}}
    }}
}

pub fn settings_section(s: &Shell) -> Option<Markup> {
    let p = prefs(s);
    Some(match s.section.as_str() {
        "search" => {
            let engines = features::search_engines(s);
            let current = if text(p, "defaultSearchID").is_empty() { text(p, "search") } else { text(p, "defaultSearchID") };
            html! {h2{"Search"}p class="section-description"{"Type a keyword and a space in the address bar to search with that engine, like “w octopus”."}
                div class="settings-group"{@for (id, name, keyword, url) in &engines {div class="list-row"{
                    (icon("search"))div{strong{(name)}small{@if !keyword.is_empty(){kbd{(keyword)}" "}(readable(url))}}
                    @if current == id {span class="badge"{"Default"}} @else {button class="button" data-op=(if ["duckDuckGo","google","bing"].contains(&id.as_str()) {"preference"} else {"setting"}) data-key=(if ["duckDuckGo","google","bing"].contains(&id.as_str()) {"search"} else {"defaultSearchID"}) data-value=(id) data-reset-custom=[["duckDuckGo","google","bing"].contains(&id.as_str()).then_some("true")]{"Make default"}}
                    @if array(&p["searchEngines"]).iter().any(|e| text(e,"id")==id) {button class="icon-button" data-op="search-engine" data-value="remove" data-id=(id) aria-label=(format!("Remove {name}")){(icon("close"))}}
                }}}
                details class="credential-disclosure"{summary{"Add a search engine"}form data-form="search-engine"{
                    label class="field"{span{"Name"}input name="name" maxlength="60" required;}
                    label class="field"{span{"Keyword"}input name="keyword" maxlength="20" placeholder="Optional, like gh";}
                    label class="field"{span{"Address, with %s for the search terms"}input name="url" type="url" placeholder="https://github.com/search?q=%s" required;}
                    button class="button primary" type="submit"{"Add engine"}
                }}
            }
        }
        "autofill" => html! {h2{"Autofill"}p class="section-description"{"Addresses are saved on this Mac. Fill a form from the page menu → Fill address."}
            div class="settings-group"{(module_toggle(s, "autofill", "Address autofill", "Offer saved addresses in the page menu."))}
            @if features::on(s, "autofill") {
            @for a in array(&p["addresses"]) {div class="list-row"{(icon("user"))div{strong{(text(a,"name"))}small{(text(a,"street"))" "(text(a,"city"))}}button class="icon-button" data-op="address-book" data-value="remove" data-id=(text(a,"id")) aria-label="Remove address"{(icon("close"))}}}
            details class="credential-disclosure"{summary{"Add an address"}form data-form="address-book"{
                @for (key, label) in [("name","Full name"),("organization","Organization"),("street","Street address"),("city","City"),("region","State or region"),("postalCode","Postal code"),("country","Country"),("email","Email"),("phone","Phone")] {label class="field"{span{(label)}input name=(key) maxlength="200" autocomplete="off";}}
                button class="button primary" type="submit"{"Save address"}
            }}
            }
            @if features::on(s, "autofill") {
                h3{"Payment cards"}
                @for c in array(&s.snapshot["cards"]) {div class="list-row"{(icon("key"))div{strong{(text(c,"name"))" ····"(text(c,"last4"))}small{"Expires "(text(c,"expiry"))}}button class="icon-button" data-op="card" data-value="remove" data-id=(text(c,"id")) aria-label="Remove card"{(icon("close"))}}}
                @if !s.private() {details class="credential-disclosure"{summary{"Add a card"}form data-form="card"{
                    label class="field"{span{"Name on card"}input name="name" maxlength="80" autocomplete="off";}
                    label class="field"{span{"Card number"}input name="number" inputmode="numeric" maxlength="23" autocomplete="off" spellcheck="false";}
                    label class="field"{span{"Expiry (MM/YY)"}input name="expiry" maxlength="7" placeholder="08/29" autocomplete="off";}
                    p class="field-help"{"Saved in macOS Keychain. The security code is never stored; you enter it each time."}
                    button class="button primary" type="submit"{"Save card"}
                }}}
            }
            p class="field-help"{"Passwords are in Settings → Passwords."}
        },
        "performance" => {
            let rows = array(&s.snapshot["tabResources"]);
            html! {h2{"Performance"}
                div class="settings-group"{(module_toggle(s, "tab-sleep", "Sleeping tabs", "Sleeping tabs keep their place and reload when you select them. Tabs playing sound never sleep."))}
                @if features::on(s, "tab-sleep") {label class="control-label"{"Put inactive tabs to sleep after"}(choice("sleepAfterMinutes", p["sleepAfterMinutes"].as_i64().unwrap_or(60), &[(0,"Never"),(15,"15 min"),(30,"30 min"),(60,"1 hour"),(120,"2 hours"),(240,"4 hours")]))}
                div class="settings-group"{(module_toggle(s, "limiter", if style(s) == "gx" {"GX Control"} else {"Resource limits"}, "Put background tabs to sleep when memory or processor use passes a limit."))}
                @if features::on(s, "limiter") {(limiter_controls(s))}
                (setting_toggle("Battery saver", "On battery power, background tabs sleep after 5 minutes and background music stops.", "batterySaver", flag(p,"batterySaver")))
                h3{"Tabs by resource use"}
                @if rows.is_empty() {p class="field-help"{"Measuring open tabs…"}}
                @else {div class="task-table" role="table" aria-label="Tabs by resource use"{
                    div class="task-row head" role="row"{span role="columnheader"{"Tab"}span role="columnheader"{"Memory"}span role="columnheader"{"CPU"}span{}}
                    @for r in rows {div class="task-row" role="row"{span role="cell" class="task-name"{(text(r,"title"))}span role="cell"{(format!("{:.0} MB", r["memory"].as_f64().unwrap_or(0.)))}span role="cell"{(format!("{:.0}%", r["cpu"].as_f64().unwrap_or(0.)))}span class="button-row"{button class="button quiet" data-op="tab-action" data-value="sleep" data-id=(text(r,"id")) disabled[r["id"]==s.active()["id"]]{"Sleep"}button class="button quiet" data-op="closeTab" data-id=(text(r,"id")){"End"}}}}
                }p class="field-help"{"WebKit tabs report the memory of their web process; Chromium tabs report JavaScript memory."}}
            }
        }
        "shortcuts" => {
            let map = features::shortcuts(s);
            html! {h2{"Keyboard shortcuts"}p class="section-description"{"Change or remove the shortcut for any action. Shortcuts work in pages and in the browser."}
                div class="settings-group shortcut-list"{@for (id, label, glyph, _) in ACTIONS.iter().filter(|a| features::action_on(s, a.0)) {
                    @let keys: Vec<&String> = map.iter().filter(|(_, a)| a == id).map(|(b, _)| b).collect();
                    div class="list-row"{(icon(glyph))div{strong{(label)}}
                        span class="shortcut-keys"{@for k in &keys {kbd{(pretty(k))}}}
                        @if s.recording == *id {button class="button primary recording" data-op="record-shortcut" data-value="" data-recording=(id){"Press keys… (Esc cancels)"}}
                        @else {button class="button quiet" data-op="record-shortcut" data-value=(id){(if keys.is_empty() {"Set"} else {"Change"})}}
                        @if p["shortcuts"][*id].is_string() {button class="button quiet" data-op="shortcut" data-action=(id) data-value="" title="Use the standard shortcut"{"Reset"}}
                        @if !keys.is_empty() {button class="icon-button" data-op="shortcut" data-action=(id) data-value="none" aria-label=(format!("Remove the shortcut for {label}")){(icon("close"))}}
                    }
                }}
                h3{"Command chains"}
                div class="settings-group"{(module_toggle(s, "command-chains", "Command chains", "Run several actions in a row from the command bar (⌘K)."))}
                @if features::on(s, "command-chains") {
                @for c in array(&p["commandChains"]) {div class="list-row"{(icon("code"))div{strong{(text(c,"name"))}small{(array(&c["steps"]).iter().filter_map(Value::as_str).map(features::action_label).collect::<Vec<_>>().join(" → "))}}button class="icon-button" data-op="chain" data-value="remove" data-id=(text(c,"id")) aria-label="Remove chain"{(icon("close"))}}}
                details class="credential-disclosure"{summary{"Create a chain"}form data-form="chain"{
                    label class="field"{span{"Name"}input data-name="true" value=(s.name.as_str()) maxlength="60";}
                    @for step in 0..4 {label class="field"{span{"Step "(step+1)}select name="steps"{option value=""{"—"}@for (id,label,_,_) in ACTIONS {option value=(id){(label)}}}}}
                    button class="button primary" type="submit"{"Save chain"}
                }}
                }
            }
        }
        _ => return None,
    })
}

/// Asks before a shortcut moves from the action that has it.
pub fn shortcut_conflict(menu: &str) -> Markup {
    let parts: Vec<&str> = menu.trim_start_matches("shortcut-conflict:").split('\t').collect();
    fn label(id: &str) -> &str {
        ACTIONS.iter().find(|a| a.0 == id).map(|a| a.1).unwrap_or(id)
    }
    html! {@if let [action, other, binding] = parts[..] {
        p{kbd{(pretty(binding))}" is already the shortcut for "(label(other))". Use it for "(label(action))" instead? "(label(other))" will have no shortcut."}
        div class="button-row"{
            button class="button" data-op="escape"{"Cancel"}
            button class="button primary" data-op="shortcut" data-action=(action) data-value=(binding) data-confirm="true"{"Use for "(label(action))}
        }
    }}
}
pub fn pretty(binding: &str) -> String {
    binding
        .split('+')
        .map(|p| match p {
            "ctrl" => "⌃".to_string(),
            "alt" => "⌥".into(),
            "shift" => "⇧".into(),
            "cmd" => "⌘".into(),
            "tab" => "⇥".into(),
            "esc" => "Esc".into(),
            "delete" => "⌫".into(),
            "enter" => "↩".into(),
            "space" => "Space".into(),
            k => k.to_uppercase(),
        })
        .collect()
}

pub fn privacy_extra(s: &Shell) -> Markup {
    let p = prefs(s);
    let rules = array(&p["customBlockList"]).len() + array(&p["customCosmetic"]).len();
    let quit_clears = ["clearHistoryOnQuit", "clearCookiesOnQuit", "clearCacheOnQuit"].iter().filter(|k| flag(p, k)).count();
    html! {
        div class="settings-group"{
            (setting_toggle("Upgrade connections to HTTPS", "Load the secure version of sites when one exists.", "httpsUpgrade", p["httpsUpgrade"].as_bool().unwrap_or(true)))
            (setting_toggle("Block third-party cookies", "Sites can’t follow you with cookies set by other sites.", "blockThirdPartyCookies", p["blockThirdPartyCookies"].as_bool().unwrap_or(true)))
            (setting_toggle("Remove tracking from links", "Strip click and campaign identifiers such as utm_source and fbclid from addresses, and open AMP pages from the publisher.", "stripTracking", p["stripTracking"].as_bool().unwrap_or(true)))
            (setting_toggle("Hide your local IP address", "WebRTC calls won’t reveal your network address. WebKit tabs always do this.", "hideLocalIP", p["hideLocalIP"].as_bool().unwrap_or(true)))
            (module_toggle(s, "cookie-banners", "Hide cookie banners", "Hide common consent pop-ups. Sites may treat this as no answer."))
        }
        (filter_lists(s))
        (site_settings_list(s))
        details class="credential-disclosure"{summary{"Custom blocking rules"@if rules > 0 {" ("(rules)")"}}form data-form="custom-rules"{
            p class="field-help"{"Paste domains, hosts-file lines, rules like ||ads.example.com^ or element rules like example.com##.banner."}
            textarea name="rules" rows="5" spellcheck="false" placeholder="||ads.example.com^\nexample.com##.banner"{(array(&p["customBlockList"]).iter().chain(array(&p["customCosmetic"])).filter_map(Value::as_str).take(400).collect::<Vec<_>>().join("\n"))}
            div class="button-row"{button class="button" type="button" data-op="custom-rules" data-value="import"{"Import list file…"}@if rules > 0 {button class="button" type="button" data-op="custom-rules" data-value="clear"{"Remove all"}}button class="button primary" type="submit"{"Save rules"}}
        }}
        div class="settings-group"{
            div class="list-row"{div{strong{"Clear browsing data"}small{"History, cookies, cache and the download list."}}button class="button" data-op="menu" data-value="clear-data"{"Clear…"}}
            @if !s.private() {
                details class="credential-disclosure"{summary{"Clear when Neutrino quits"@if quit_clears > 0 {" ("(quit_clears)" on)"}}
                    (setting_toggle("History", "Every Profile’s browsing history.", "clearHistoryOnQuit", flag(p, "clearHistoryOnQuit")))
                    (setting_toggle("Cookies and site data", "Signs you out of websites.", "clearCookiesOnQuit", flag(p, "clearCookiesOnQuit")))
                    (setting_toggle("Cache", "Saved copies of pages and images.", "clearCacheOnQuit", flag(p, "clearCacheOnQuit")))
                }
            }
            div class="list-row"{div{strong{"Site data"}small{"See and remove what each site stores on this Mac."}}button class="button" data-op="site-data" data-value="load"{"Show sites"}}
            @if let Some(list) = s.snapshot["siteData"].as_array() {
                @if list.is_empty() {p class="field-help"{"No sites have stored data."}}
                @for d in list.iter().take(300) {div class="list-row"{(site(&json!({"url":format!("https://{}/",text(d,"host"))})))div{strong{(text(d,"host"))}small{(text(d,"detail"))}}button class="button quiet" data-op="site-data" data-value="remove" data-host=(text(d,"host")){"Remove"}}}
            }
        }
    }
}

/// Vivaldi's Feeds panel: newest entries from every subscription, unread first in weight.
pub fn feeds_panel(s: &Shell) -> Markup {
    let feeds = profile_items(s, "feeds");
    let mut entries: Vec<(&Value, &Value)> = feeds.iter().flat_map(|f| array(&f["entries"]).iter().map(move |e| (*f, e))).collect();
    entries.sort_by(|a, b| b.1["time"].as_f64().unwrap_or(0.).total_cmp(&a.1["time"].as_f64().unwrap_or(0.)));
    let unread = entries.iter().filter(|(_, e)| !flag(e, "read")).count();
    html! {div class="feeds-panel"{
        form class="route-form" data-form="feed"{
            input type="url" name="url" placeholder="https://example.com/feed.xml" aria-label="Feed address" spellcheck="false" autocomplete="off";
            button class="button" type="submit"{"Subscribe"}
        }
        @if feeds.is_empty() {(crate::render::empty("No feeds yet", "Subscribe to a site’s RSS or Atom feed. Sites that offer one show Subscribe in the page menu.", "feed"))}
        @else {
            div class="feeds-actions"{span{(unread)" unread"}span class="spacer"{}button class="button quiet" data-op="feed" data-value="refresh"{"Refresh"}@if unread > 0 {button class="button quiet" data-op="feed" data-value="read-all"{"Mark all read"}}}
            div class="filter-chips feed-list"{@for f in &feeds {span class="chip"{(text(f,"title"))@if !text(f,"error").is_empty(){" · "(text(f,"error"))}button class="chip-remove" data-op="feed" data-value="remove" data-id=(text(f,"id")) aria-label=(format!("Unsubscribe from {}", text(f,"title"))){(icon("close"))}}}}
            div class="feed-entries"{@for (f, e) in entries.iter().take(80) {
                button class=(if flag(e,"read") {"feed-entry read"} else {"feed-entry"}) data-op="feed" data-value="open" data-id=(text(e,"id")){strong{(text(e,"title"))}small{(text(f,"title"))@if !text(e,"date").is_empty(){" · "(text(e,"date"))}}}
            }}
        }
    }}
}

/// Asks to save a password after a sign-in, above the page so nothing covers it.
pub fn password_prompt(s: &Shell) -> Markup {
    let p = &s.snapshot["passwordPrompt"];
    html! {@if p.is_object() {
        div class="prompt-bar" role="alertdialog" aria-label="Save password"{
            (icon("key"))
            span{strong{(if flag(p, "update") {"Update the saved password for "} else {"Save password for "})(host(text(p, "origin")))"?"}@if !text(p, "username").is_empty() {small{(text(p, "username"))}}}
            span class="spacer"{}
            button class="button quiet" data-op="password-prompt" data-value="never"{"Never for this site"}
            button class="button quiet" data-op="password-prompt" data-value="dismiss"{"Not now"}
            button class="button primary" data-op="password-prompt" data-value="save"{(if flag(p, "update") {"Update"} else {"Save"})}
        }
    }}
}

/// Subscribed filter lists: the common ones, then any added by address.
fn filter_lists(s: &Shell) -> Markup {
    let lists = array(&prefs(s)["filterLists"]);
    let saved = |id: &str| lists.iter().find(|l| text(l, "id") == id);
    let status = |l: Option<&Value>| -> String {
        match l {
            Some(l) if !text(l, "error").is_empty() => text(l, "error").to_string(),
            Some(l) if l["domains"].is_number() => format!("{} sites and {} element rules", l["domains"].as_u64().unwrap_or(0), l["cosmetic"].as_u64().unwrap_or(0)),
            Some(l) if flag(l, "enabled") => "Downloading…".into(),
            _ => String::new(),
        }
    };
    let custom: Vec<&Value> = lists.iter().filter(|l| !features::FILTER_LISTS.iter().any(|f| f.0 == text(l, "id"))).collect();
    let on = lists.iter().filter(|l| flag(l, "enabled")).count();
    html! {@if !s.private() {
        details class="credential-disclosure"{summary{"Filter lists"@if on > 0 {" ("(on)" on)"}}
            p class="field-help"{"Lists download from their publishers and update once a week."}
            div class="settings-group"{
                @for (id, title, _, detail) in features::FILTER_LISTS {
                    @let list = saved(id);
                    @let enabled = list.is_some_and(|l| flag(l, "enabled"));
                    button class="toggle-row" data-op="filter-list" data-value="toggle" data-id=(id) role="switch" aria-checked=(enabled.to_string()){span{strong{(title)}small{(if enabled {status(list)} else {detail.to_string()})}}span class=(if enabled{"switch on"}else{"switch"}){span{}}}
                }
                @for l in &custom {
                    div class="list-row"{div{strong{(text(l,"title"))}small{(status(Some(l)))}}
                        button class="button quiet" data-op="filter-list" data-value="toggle" data-id=(text(l,"id")){(if flag(l,"enabled") {"Turn off"} else {"Turn on"})}
                        button class="icon-button" data-op="filter-list" data-value="remove" data-id=(text(l,"id")) aria-label=(format!("Remove {}", text(l,"title"))){(icon("close"))}}
                }
            }
            form class="route-form" data-form="filter-list"{
                input type="url" name="url" placeholder="https://example.com/list.txt" aria-label="List address" spellcheck="false" autocomplete="off";
                button class="button" type="submit"{"Add list"}
                @if on > 0 {button class="button quiet" type="button" data-op="filter-list" data-value="refresh"{"Update now"}}
            }
        }
    }}
}

/// Every site with its own settings: permissions, scripts, styles, zoom.
fn site_settings_list(s: &Shell) -> Markup {
    let p = prefs(s);
    let mut hosts: Vec<&String> = p["siteSettings"].as_object().map(|o| o.keys().collect()).unwrap_or_default();
    for host in p["siteZoom"].as_object().map(|o| o.keys().collect::<Vec<_>>()).unwrap_or_default() {
        if !hosts.contains(&host) {
            hosts.push(host);
        }
    }
    hosts.sort();
    let summary = |host: &str| {
        let v = &p["siteSettings"][host];
        let mut parts: Vec<String> = vec![];
        if flag(v, "blockScripts") { parts.push("JavaScript off".into()); }
        if flag(v, "allowPopups") { parts.push("Pop-ups allowed".into()); }
        if flag(v, "muted") { parts.push("Muted".into()); }
        for (key, label) in [("camera", "Camera"), ("microphone", "Microphone")] {
            if !text(v, key).is_empty() { parts.push(format!("{label}: {}", if text(v, key) == "allow" {"allowed"} else {"blocked"})); }
        }
        if !text(v, "filter").is_empty() { parts.push("Page filter".into()); }
        if !text(v, "css").is_empty() || !array(&v["hide"]).is_empty() { parts.push("Custom styles".into()); }
        if flag(v, "forget") { parts.push("Forgotten on close".into()); }
        if let Some(zoom) = p["siteZoom"][host].as_f64() { parts.push(format!("Zoom {:.0}%", zoom * 100.)); }
        parts.join(" · ")
    };
    html! {@if !hosts.is_empty() {
        details class="credential-disclosure"{summary{"Site settings ("(hosts.len())")"}
            div class="settings-group"{@for host in &hosts {div class="list-row"{(icon("globe"))div{strong{(host)}small{(summary(host))}}button class="button quiet" data-op="site-reset" data-host=(host){"Reset"}}}}
        }
    }}
}

pub fn general_extra(s: &Shell) -> Markup {
    let p = prefs(s);
    let mode = if !array(&p["startupPages"]).is_empty() && !flag(p, "restoreSession") { "pages" } else if flag(p, "restoreSession") { "restore" } else { "start" };
    html! {
        label class="control-label"{"On startup"}
        (segments("setting", "startupMode", mode, &[("restore","Reopen tabs"),("start","Start page"),("pages","Specific pages")]))
        @if mode == "pages" {form data-form="startup-pages"{label class="field"{span{"Pages, one per line"}textarea name="pages" rows="3" spellcheck="false"{(array(&p["startupPages"]).iter().filter_map(Value::as_str).collect::<Vec<_>>().join("\n"))}}button class="button" type="submit"{"Save pages"}}}
        label class="control-label"{"Archive unused tabs after"}
        (choice("autoArchiveDays", p["autoArchiveDays"].as_i64().unwrap_or(0), &[(0,"Never"),(1,"1 day"),(7,"7 days"),(14,"14 days"),(30,"30 days")]))
        div class="settings-group"{
            div class="list-row"{div{strong{"Downloads"}small{(if text(p,"downloadFolder").is_empty(){"Ask where to save each file".to_string()}else{format!("Save to {}", text(p,"downloadFolder"))})}}button class="button" data-op="native" data-action="chooseDownloadFolder"{"Choose folder…"}@if !text(p,"downloadFolder").is_empty(){button class="button quiet" data-op="native" data-action="clearDownloadFolder"{"Always ask"}}}
            @if style(s) == "arc" {(module_toggle(s, "little-arc", "Little Arc", "Open links from other apps in a small window. Keep it as a tab or close it."))}
            (module_toggle(s, "peek", "Peek at links", "Shift-click a link to preview it in a floating window. WebKit tabs only."))
            (module_toggle(s, "mouse-gestures", "Mouse gestures", "Hold ⌥ and drag on a page: left goes back, right forward, up then down reloads."))
            @if style(s) == "gx" {(module_toggle(s, "tab-islands", "Tab islands", "Tabs you open from a page stay beside it as an island."))}
        }
        (link_routes(s))
    }
}

/// Rules that send links from other apps to a Space, like Arc's Air Traffic Control.
fn link_routes(s: &Shell) -> Markup {
    let spaces: Vec<&Value> = array(&s.snapshot["spaces"]).iter().filter(|v| v["profileID"] == s.snapshot["session"]["profileID"]).collect();
    let name = |id: &str| spaces.iter().find(|v| text(v, "id") == id).map(|v| text(v, "name").to_string()).unwrap_or_else(|| "a removed Space".into());
    let routes = array(&prefs(s)["linkRoutes"]);
    html! {
        @if spaces.len() > 1 && !s.private() {
            div class="settings-group"{
                (module_toggle(s, "link-routes", if style(s) == "arc" {"Air Traffic Control"} else {"Route links by site"}, "Links from other apps open in the Space you choose."))
                @if features::on(s, "link-routes") {
                @for (i, route) in routes.iter().enumerate() {
                    div class="list-row"{div{strong{(text(route,"host"))}small{"Opens in "(name(text(route,"spaceID")))}}button class="button quiet" data-op="link-route" data-value="remove" data-index=(i){"Remove"}}
                }
                form class="route-form" data-form="link-route"{
                    input type="text" name="host" placeholder="github.com" aria-label="Site" spellcheck="false" autocomplete="off";
                    select name="space" aria-label="Space"{@for space in &spaces {option value=(text(space,"id")){(text(space,"name"))}}}
                    button class="button" type="submit"{"Add rule"}
                }
                }
            }
        }
    }
}

/// Memory, processor and network limits, shown in Settings and in Opera GX's Control panel.
pub fn limiter_controls(s: &Shell) -> Markup {
    let p = prefs(s);
    html! {
        label class="control-label"{"Memory limit"}(choice("memoryLimitMB", p["memoryLimitMB"].as_i64().unwrap_or(0), &[(0,"Off"),(1024,"1 GB"),(2048,"2 GB"),(4096,"4 GB"),(8192,"8 GB")]))
        label class="control-label"{"CPU limit"}(choice("cpuLimit", p["cpuLimit"].as_i64().unwrap_or(0), &[(0,"Off"),(25,"25%"),(50,"50%"),(75,"75%")]))
        p class="field-help"{"Above a limit, the least recently used background tabs go to sleep until usage drops."}
        label class="control-label"{"Network limit for Chromium tabs"}(choice("networkLimitKBps", p["networkLimitKBps"].as_i64().unwrap_or(0), &[(0,"Off"),(256,"256 KB/s"),(1024,"1 MB/s"),(5120,"5 MB/s"),(10240,"10 MB/s")]))
    }
}

/// Opera GX's Control panel: limiters, the tabs using the most, and the cleaner.
pub fn gx_control(s: &Shell) -> Markup {
    let rows: Vec<&Value> = array(&s.snapshot["tabResources"]).iter().take(3).collect();
    html! {div class="gx-control"{
        @if features::on(s, "limiter") {h3{"Limiters"}(limiter_controls(s))}
        h3{"Hot tabs"}
        @if rows.is_empty() {p class="field-help"{"Measuring open tabs…"}}
        @for r in rows {div class="list-row"{div{strong{(text(r,"title"))}small{(format!("{:.0} MB · {:.0}% CPU", r["memory"].as_f64().unwrap_or(0.), r["cpu"].as_f64().unwrap_or(0.)))}}button class="button quiet" data-op="tab-action" data-id=(text(r,"id")) data-value="sleep"{"Sleep"}}}
        h3{"GX Cleaner"}
        div class="list-row"{div{strong{"Clean browsing data"}small{"Cache, cookies, history and downloads, by time range."}}button class="button" data-op="menu" data-value="clear-data"{"Clean…"}}
        @if features::on(s, "fake-history") && !s.private() {
            h3{"Fake My History"}
            p class="field-help"{"Adds visits of one kind to your history, dated over the last day. They are ordinary history entries you can delete."}
            div class="button-row"{@for (key, label, _) in features::FAKE_HISTORY {button class="button" data-op="fake-history" data-value=(key){(label)}}}
        }
    }}
}

pub fn appearance_extra(s: &Shell) -> Markup {
    let p = prefs(s);
    let schedule = &p["themeSchedule"];
    let gx = style(s) == "gx";
    html! {
        h3{"Start page"}
        div class="settings-group"{
            @if start_options(s).is_empty() {p class="field-help"{"This layout opens new tabs from the command bar, without a start page."}}
            @for (key, label) in start_options(s) {
                @let on = start_option(s, key);
                button class="toggle-row" data-op="setting" data-key="startPage" data-json=(start_page_with(p, key, !on)) role="switch" aria-checked=(on.to_string()){span{strong{(label)}}span class=(if on{"switch on"}else{"switch"}){span{}}}
            }
            (module_toggle(s, "wallpapers", "Wallpapers", "Use your own picture behind the start page."))
            @if features::on(s, "wallpapers") {
                div class="list-row"{div{strong{"Live wallpaper"}small{"Animated, for when no picture is chosen. Follows Reduce motion."}}}
                (crate::render::segments("setting", "liveWallpaper", text(p, "liveWallpaper"), &[("", "Off"), ("aurora", "Aurora"), ("waves", "Waves"), ("embers", "Embers")]))
            }
            @if features::on(s, "wallpapers") {div class="list-row"{div{strong{"Background image"}small{(if text(&s.snapshot,"wallpaper").is_empty(){"None"}else{"Chosen"})}}button class="button" data-op="native" data-action="chooseWallpaper"{"Choose image…"}@if !text(&s.snapshot,"wallpaper").is_empty(){button class="button quiet" data-op="native" data-action="removeWallpaper"{"Remove"}}}}
        }
        h3{"Light and dark schedule"}
        div class="settings-group"{(module_toggle(s, "theme-schedule", "Theme schedule", "Switch between light and dark at the times you set."))}
        @if features::on(s, "theme-schedule") {form class="schedule-form" data-form="schedule"{
            label class="check-row"{input type="checkbox" name="enabled" checked[flag(schedule,"enabled")];span{strong{"Switch automatically"}small{"Use light mode during the day and dark mode at night."}}}
            div class="color-pair"{label class="field"{span{"Light from"}input type="time" name="light" value=(if text(schedule,"light").is_empty(){"07:00"}else{text(schedule,"light")});}label class="field"{span{"Dark from"}input type="time" name="dark" value=(if text(schedule,"dark").is_empty(){"19:00"}else{text(schedule,"dark")});}}
            button class="button" type="submit"{"Save schedule"}
        }}
        h3{(if gx {"Sounds and music"} else {"Sounds"})}
        div class="settings-group"{
            (module_toggle(s, "sounds", "Browser sounds", "Interface and keyboard sounds, and background music."))
            @if features::on(s, "sounds") {
            (setting_toggle("Interface sounds", "Soft clicks when you open, close and switch tabs.", "interfaceSounds", p["interfaceSounds"].as_bool().unwrap_or(gx)))
            (setting_toggle("Keyboard sounds", "A key click as you type.", "keyboardSounds", flag(p,"keyboardSounds")))
            (setting_toggle("Background music", "A quiet generated soundtrack while the browser is in front.", "backgroundMusic", flag(p,"backgroundMusic")))
            }
        }
        div class="settings-group"{(module_toggle(s, "interface-css", "Interface CSS", "Restyle Neutrino’s own interface with your CSS."))}
        @if features::on(s, "interface-css") {details class="credential-disclosure"{summary{"Interface CSS"}form data-form="interface-css"{
            p class="field-help"{"Restyle Neutrino’s own interface. Use Site CSS in the page menu for websites."}
            textarea name="css" rows="6" spellcheck="false" placeholder=".tab-row { border-radius: 4px; }"{(text(p,"interfaceCSS"))}
            div class="button-row"{button class="button quiet" type="button" data-op="setting" data-key="interfaceCSS" data-value=""{"Remove"}button class="button primary" type="submit"{"Apply"}}
        }}}
    }
}

/// The start-page options with one of them changed, as JSON.
fn start_page_with(p: &Value, key: &str, on: bool) -> String {
    let mut next = if p["startPage"].is_object() { p["startPage"].clone() } else { json!({}) };
    next[key] = json!(on);
    next.to_string()
}

pub fn folder_menu_extra(id: &str, current: &str) -> Markup {
    html! {div class="menu-label"{"Color"}div class="folder-colors" role="group" aria-label="Folder color"{@for (value, label) in FOLDER_COLORS {button class=(format!("folder-color {value}{}", if current==*value {" selected"} else {""})) data-op="folder-color" data-id=(id) data-value=(value) aria-label=(label) aria-pressed=((current==*value).to_string()) title=(label){}}}}
}

/// The person's interface CSS, already checked to contain no markup.
pub fn interface_css(s: &Shell) -> Option<String> {
    if !features::on(s, "interface-css") {
        return None;
    }
    let css = text(prefs(s), "interfaceCSS");
    (!css.is_empty() && !css.contains('<') && css.len() <= 65_536).then(|| css.to_string())
}

pub fn hover_card(s: &Shell, t: &Value) -> String {
    let id = text(t, "id");
    let mut parts = vec![title(t).to_string()];
    if !text(t, "url").is_empty() {
        parts.push(readable(text(t, "url")));
    }
    if sleeping(s, id) {
        parts.push("Sleeping · reloads when selected".into());
    } else if audible(s, id) {
        parts.push("Playing sound".into());
    }
    parts.join("\n")
}
