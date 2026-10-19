// SPDX-License-Identifier: MPL-2.0
use crate::state::{array, flag, text, Shell};
use maud::{html, Markup, PreEscaped};
use serde_json::{json, Value};

pub(crate) fn icon(name: &str) -> Markup {
    html! {svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="var(--icon-stroke,1.7)" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" {use href=(format!("#glyph-{name}"));}}
}
fn icon_definitions(s: &Shell) -> Markup {
    let names = [
        "back", "forward", "down", "close", "plus", "search", "reload", "check", "more", "sidebar",
        "split", "folder", "bookmark", "history", "download", "settings", "globe", "lock",
        "shield", "pin", "edit", "sun", "moon", "spark", "undo", "arrow", "user", "grid",
        "external", "grip", "key", "book", "activity", "camera", "plug", "appearance", "quote",
        "focus", "copy", "kebab", "menu", "home", "volume", "muted", "code", "print", "pip", "trash",
        "minus", "pause", "play", "panel", "star",
    ];
    html! {svg class="icon-definitions" aria-hidden="true"{defs{@for name in names{
        @let key = match name {"bookmark"=>"bookmarks","grid"=>"modules","plus"=>"newTab","download"=>"downloads","edit"=>"notes","book"=>"reader","activity"=>"resources","camera"=>"screenshot","focus"=>"focus",v=>v};
        @let pack = text(&s.config()["theme"],"iconPack");
        @let custom = if text(&s.snapshot["svgIcons"],key).is_empty(){text(&s.snapshot["svgIcons"],name)}else{text(&s.snapshot["svgIcons"],key)};
        @let path = if (pack=="module" || pack.is_empty()) && crate::icons::valid_path(custom){custom}else{crate::icons::path(name,pack)};
        @let filled = pack=="solid";
        symbol id=(format!("glyph-{name}")) viewBox="0 0 24 24"{
            @if filled && ["back","forward","reload"].contains(&name){circle cx="12" cy="12" r="10" fill="currentColor" stroke="none"{}path d=(path) stroke="var(--rail)" fill="none"{}}
            @else {path d=(path) fill=(if filled && ["bookmark","grid","folder","pin"].contains(&name){"currentColor"}else{"none"}){}}
        }
    }}}}
}
fn theme_style(s: &Shell) -> String {
    let t = &s.config()["theme"];
    let mut style = format!("--component-radius:{}px;--font-scale:{};--spacing-scale:{};--theme-border:{}px;--theme-shadow:{};--icon-stroke:{}",t["cornerRadius"].as_f64().unwrap_or(6.).clamp(0.,24.),t["fontScale"].as_f64().unwrap_or(1.).clamp(0.85,1.4),t["spacingScale"].as_f64().unwrap_or(1.).clamp(0.75,1.5),t["borderWidth"].as_f64().unwrap_or(1.).clamp(0.,2.),t["shadowStrength"].as_f64().unwrap_or(0.).clamp(0.,1.),t["iconStroke"].as_f64().unwrap_or(1.7).clamp(1.,2.5));
    let valid = |v: &str| {
        v.trim_start_matches('#').len() == 6
            && v.trim_start_matches('#')
                .bytes()
                .all(|b| b.is_ascii_hexdigit())
    };
    let accent = text(t, "accentHex").trim_start_matches('#');
    if valid(accent) {
        style.push_str(&format!(
            ";--accent:#{accent};--tint:#{accent};--tint-light:#{accent}"
        ));
    }
    let surface = text(t, "surfaceHex").trim_start_matches('#');
    let ink = text(t, "textHex").trim_start_matches('#');
    if valid(surface) && valid(ink) {
        style.push_str(&format!(
            ";--bg:#{surface};--rail:#{surface};--surface:#{surface};--ink:#{ink};--muted:#{ink}"
        ));
    }
    for (component, key) in [
        ("tabs", "tabsAppearance"),
        ("navigation", "navigationAppearance"),
        ("sidebar", "sidebarAppearance"),
    ] {
        let a = &t[key];
        style.push_str(&format!(
            ";--{component}-radius:{}px;--{component}-font:{};--{component}-spacing:{}",
            a["cornerRadius"]
                .as_f64()
                .unwrap_or(t["cornerRadius"].as_f64().unwrap_or(6.))
                .clamp(0., 24.),
            a["fontScale"]
                .as_f64()
                .unwrap_or(t["fontScale"].as_f64().unwrap_or(1.))
                .clamp(0.85, 1.4),
            if text(a, "density") == "compact" {
                0.85
            } else {
                1.
            } * t["spacingScale"].as_f64().unwrap_or(1.).clamp(0.75, 1.5)
        ));
    }
    style
}
pub(crate) fn button(label: &str, op: &str, glyph: &str) -> Markup {
    html! {button class="icon-button" data-op=(op) title=(label) aria-label=(label) {(icon(glyph))}}
}
pub(crate) fn action(label: &str, op: &str, primary: bool) -> Markup {
    html! {button class=(if primary{"button primary"}else{"button"}) data-op=(op) {(label)}}
}
fn field(label: &str, key: &str, value: &str, invalid: bool) -> Markup {
    html! {label class="field" {span{(label)}input id=(format!("setup-{key}")) data-setup=(key) value=(value) maxlength="80" autocomplete="off" aria-invalid=(invalid.to_string()) aria-describedby=[invalid.then(||format!("error-{key}"))];
        @if invalid {span class="field-error" id=(format!("error-{key}")){"Enter a name to continue."}}
    }}
}

pub(crate) fn toggle(label: &str, detail: &str, key: &str, value: bool, setup: bool) -> Markup {
    html! {button class="toggle-row" data-op=(if setup{"setup-field"}else{"preference"}) data-key=(key) data-value=((!value).to_string()) data-type="bool" role="switch" aria-checked=(value.to_string()) {span {strong{(label)}@if !detail.is_empty(){small{(detail)}}} span class=(if value{"switch on"}else{"switch"}) {span{}}}}
}
pub(crate) fn horizontal(s: &Shell) -> bool {
    ["top", "bottom"].contains(&text(&s.config()["layout"], "tabs"))
}
pub(crate) fn tab_visible(tab: &Value, s: &Shell) -> bool {
    if !tab["favoriteID"].is_null() && style(s) == "arc" && tab["id"] != s.snapshot["session"]["selectedTabID"] {
        return false;
    }
    if text(tab, "url").is_empty()
        && text(tab, "title") == "New tab"
        && s.snapshot["chromePageCounts"][text(tab, "id")]
            .as_u64()
            .unwrap_or(0)
            < 2
    {
        return false;
    }
    if !flag(&s.config()["layout"], "treeTabs") {
        return true;
    }
    let mut parent = text(tab, "parentID");
    let mut visited = std::collections::HashSet::new();
    while !parent.is_empty() && visited.insert(parent) {
        if let Some(p) = s.tabs().iter().find(|t| text(t, "id") == parent) {
            if flag(p, "collapsed") {
                return false;
            }
            parent = text(p, "parentID");
        } else {
            break;
        }
    }
    true
}
pub(crate) fn site(tab: &Value) -> Markup {
    let favicon = text(tab, "faviconDataURL");
    if favicon.starts_with("data:image/png;base64,") && favicon.len() < 12000 {
        return html! {img class="site-icon favicon" src=(favicon) alt="";};
    }
    let address = text(tab, "url");
    if address.is_empty() {
        return html! {span class="site-icon blank-icon"{(icon("plus"))}};
    }
    let hash = address
        .bytes()
        .fold(0u32, |h, b| h.wrapping_mul(31).wrapping_add(b as u32));
    let initial = host(address)
        .chars()
        .next()
        .unwrap_or('N')
        .to_uppercase()
        .to_string();
    html! {span class=(format!("site-icon site-color-{}",hash%6)) aria-hidden="true"{(initial)}}
}

pub(crate) fn tab_row(t: &Value, s: &Shell, preview: bool) -> Markup {
    let selected = t["id"] == s.snapshot["session"]["selectedTabID"];
    let group = if flag(t, "pinned") {
        "pinned"
    } else if !text(t, "folderID").is_empty() {
        "folder"
    } else {
        "today"
    };
    let children = flag(&s.config()["layout"], "treeTabs")
        && s.tabs().iter().any(|x| x["parentID"] == t["id"]);
    let sleeping = crate::views::sleeping(s, text(t, "id"));
    html! {div class=(format!("tab-row{}{}",if selected{" active"}else{""},if sleeping{" sleeping"}else{""})) data-tab=(text(t,"id")) data-group=(group) data-folder=(text(t,"folderID")) draggable=((!preview).to_string()) {
        @if children {button class="branch" data-op="toggleBranch" data-id=(text(t,"id")) aria-label=(format!("{} {}",if flag(t,"collapsed"){"Expand"}else{"Collapse"},text(t,"title"))) {(icon(if flag(t,"collapsed"){"forward"}else{"down"}))}}
        button class="tab-select" data-op="selectTab" data-id=(text(t,"id")) aria-current=[selected.then_some("page")] aria-label=(crate::views::title(t)) title=[(!crate::features::on(s, "tab-previews")).then(|| crate::views::hover_card(s,t))] {(site(t)) span{(crate::views::title(t))}}
        (crate::views::tab_audio(s, t))
        button class="tab-close" data-op="closeTab" data-id=(text(t,"id")) title="Close tab (⌘W)" aria-label=(format!("Close {}",crate::views::title(t))) {(icon("close"))}
        button class="tab-menu" data-op="menu" data-value=(format!("tab:{}",text(t,"id"))) title="Tab options" aria-label=(format!("Options for {}",crate::views::title(t))) {(icon("more"))}
    }
    @for page in array(&s.snapshot["chromePages"][text(t,"id")]).iter().filter(|p|!flag(p,"selected") && !text(p,"url").is_empty() && !text(p,"url").starts_with("chrome://")) {
        div class="chrome-page-row" {button class="tab-select" data-op="chrome-page" data-id=(text(t,"id")) data-page=(page["id"].as_i64().unwrap_or(0)) title=(text(page,"url")){(site(page))span{(if text(page,"title").is_empty(){host(text(page,"url"))}else{text(page,"title").into()})}}button class="tab-close" data-op="chrome-page-close" data-id=(text(t,"id")) data-page=(page["id"].as_i64().unwrap_or(0)) aria-label=(format!("Close {}",text(page,"title"))){(icon("close"))}}
    } }
}
/// Ancestors a tab folder may have.
pub const MAX_FOLDER_DEPTH: usize = 3;
/// Folders inside a folder, or the top-level ones (no parent, or a parent that's gone).
pub(crate) fn subfolders<'a>(s: &'a Shell, parent: &str) -> Vec<&'a Value> {
    let folders = array(&s.snapshot["folders"]);
    folders
        .iter()
        .filter(|f| {
            let p = text(f, "parentID");
            if parent.is_empty() { p.is_empty() || !folders.iter().any(|o| text(o, "id") == p) } else { p == parent }
        })
        .collect()
}
/// How deep a folder sits: 0 at the top level.
pub(crate) fn folder_depth(s: &Shell, id: &str) -> usize {
    let folders = array(&s.snapshot["folders"]);
    let mut current = id.to_string();
    for depth in 0..=crate::render::MAX_FOLDER_DEPTH + 1 {
        match folders.iter().find(|f| text(f, "id") == current).map(|f| text(f, "parentID")) {
            Some(parent) if !parent.is_empty() && folders.iter().any(|f| text(f, "id") == parent) => current = parent.to_string(),
            _ => return depth,
        }
    }
    crate::render::MAX_FOLDER_DEPTH + 1
}
/// Whether `id` is `ancestor` or inside it.
pub(crate) fn folder_within(s: &Shell, id: &str, ancestor: &str) -> bool {
    let folders = array(&s.snapshot["folders"]);
    let mut current = id.to_string();
    for _ in 0..=crate::render::MAX_FOLDER_DEPTH + 1 {
        if current == ancestor { return true; }
        match folders.iter().find(|f| text(f, "id") == current).map(|f| text(f, "parentID")) {
            Some(parent) if !parent.is_empty() => current = parent.to_string(),
            _ => return false,
        }
    }
    false
}
/// Levels of folders below this one, counting itself.
pub(crate) fn folder_height_from(s: &Shell, id: &str, level: usize) -> usize {
    if level > crate::render::MAX_FOLDER_DEPTH { return 1; }
    1 + subfolders(s, id).iter().map(|c| folder_height_from(s, text(c, "id"), level + 1)).max().unwrap_or(0)
}
pub(crate) fn folder_height(s: &Shell, id: &str) -> usize {
    folder_height_from(s, id, 0)
}
/// Folder menu items to add a folder inside this one and move it into another.
fn folder_nesting(s: &Shell, id: &str) -> Markup {
    let max = crate::render::MAX_FOLDER_DEPTH;
    let height = folder_height(s, id);
    let parent = array(&s.snapshot["folders"]).iter().find(|f| text(f, "id") == id).map(|f| text(f, "parentID").to_string()).unwrap_or_default();
    let targets: Vec<&Value> = array(&s.snapshot["folders"]).iter().filter(|f| {
        let target = text(f, "id");
        target != parent && !folder_within(s, target, id) && folder_depth(s, target) + height <= max
    }).collect();
    html! {@if !s.private() {
        @if folder_depth(s, id) < max {button class="menu-item" data-op="menu" data-value=(format!("new-folder:{id}")){(icon("folder"))"New folder inside"}}
        @if !parent.is_empty() || !targets.is_empty() {div class="menu-separator"{}div class="menu-label"{"Move folder into"}}
        @if !parent.is_empty() {button class="menu-item" data-op="nest-folder" data-id=(id) data-parent=""{(icon("sidebar"))"Top level"}}
        @for f in targets {button class="menu-item" data-op="nest-folder" data-id=(id) data-parent=(text(f,"id")){(icon("folder"))(text(f,"name"))}}
        div class="menu-separator"{}
    }}
}
/// A tab folder with its subfolders first, then its tabs, as Arc nests them.
fn folder_group(s: &Shell, f: &Value, preview: bool, depth: usize) -> Markup {
    let children = if depth < crate::render::MAX_FOLDER_DEPTH { subfolders(s, text(f, "id")) } else { vec![] };
    html! {div class="folder-group" data-drop-group="folder" data-folder=(text(f,"id")) data-depth=(depth) data-color=[(!text(f,"color").is_empty()).then(||text(f,"color"))] {
        div class="folder-heading" draggable=((!preview && !s.private()).to_string()) data-folder-source=(text(f,"id")) tabindex="0" aria-label=(format!("Folder {}. Drag or use Option Shift arrow keys to reorder.",text(f,"name"))) {button data-op="toggleFolder" data-id=(text(f,"id")) aria-expanded=((!flag(f,"collapsed")).to_string()) {(icon(if flag(f,"collapsed"){"forward"}else{"down"}))(icon("folder"))span{(text(f,"name"))}}
            button class="icon-button" data-op="menu" data-value=(format!("folder:{}",text(f,"id"))) aria-label=(format!("Options for {}",text(f,"name"))) {(icon("more"))}}
        @if !flag(f,"collapsed"){
            @for child in &children {(folder_group(s, child, preview, depth + 1))}
            @for t in s.tabs().iter().filter(|t|!flag(t,"pinned")&&t["folderID"]==f["id"]&&tab_visible(t,s)){(tab_row(t,s,preview))}
            @if children.is_empty() && !s.tabs().iter().any(|t|t["folderID"]==f["id"]){div class="folder-empty"{"Drop tabs here"}}}
    }}
}
pub(crate) fn tab_groups(s: &Shell, preview: bool) -> Markup {
    html! {
        div class="tab-group pins" data-drop-group="pinned" aria-label="Pinned tabs" {
            @for t in s.tabs().iter().filter(|t|flag(t,"pinned")&&tab_visible(t,s)){(tab_row(t,s,preview))}
        }
        @for f in subfolders(s, "") {(folder_group(s, f, preview, 0))}
        div class="tab-group today" data-drop-group="today" aria-label="Unpinned tabs" {
            div class="group-label"{span{"Tabs"}@if !s.tab_undo.is_empty(){button data-op="undo-tabs" title="Undo the last tab move"{(icon("undo"))"Undo"}}}
            @for t in s.tabs().iter().filter(|t|!flag(t,"pinned")&&text(t,"folderID").is_empty()&&tab_visible(t,s)){(tab_row(t,s,preview))}
            button class="new-tab" data-op="newTab" {(icon("plus"))span{"New tab"}kbd{"⌘T"}}
            div class="drop-end" data-drop-group="today" {}
        }
    }
}
pub(crate) fn spaces(s: &Shell) -> Markup {
    html! {div class="spaces" aria-label="Spaces" {
        @for (index,space) in array(&s.snapshot["spaces"]).iter().filter(|v|v["profileID"]==s.snapshot["session"]["profileID"]).enumerate() {button class=(if space["id"]==s.snapshot["session"]["spaceID"]{"space-button selected"}else{"space-button"}) data-op="switchSpace" data-id=(text(space,"id")) data-space=(text(space,"id")) data-tone=(index%5) draggable=((!s.private()).to_string()) data-tip=(text(space,"name")) aria-label=(format!("Switch to {}",text(space,"name"))) aria-pressed=((space["id"]==s.snapshot["session"]["spaceID"]).to_string()) disabled[s.private()] {span class=(format!("space-symbol color-{}",index%5)){(space_mark(space))}}}
        button class="space-button space-add" data-op="menu" data-value="new-space" aria-label="Create a Space" data-tip="New Space" disabled[s.private()] {(icon("plus"))}
    }}
}
pub(crate) fn space_mark(space: &Value) -> String {
    let emoji = text(space, "emoji");
    if emoji.is_empty() { text(space, "name").chars().next().unwrap_or('S').to_string() } else { emoji.chars().take(2).collect() }
}
pub(crate) fn rail_navigation(s: &Shell) -> Markup {
    html! {div class="rail-navigation" {
        button class="icon-button" data-op="back" title="Back" aria-label="Back" disabled[!flag(&s.snapshot,"canGoBack")]{(icon("back"))}button class="icon-button" data-op="forward" title="Forward" aria-label="Forward" disabled[!flag(&s.snapshot,"canGoForward")]{(icon("forward"))}
        (button(if flag(&s.snapshot,"loading"){"Stop loading"}else{"Reload page"},if flag(&s.snapshot,"loading"){"stop"}else{"reload"},if flag(&s.snapshot,"loading"){"close"}else{"reload"}))
    }}
}
pub(crate) fn location(s: &Shell) -> Markup {
    let url = text(s.active(), "url");
    html! {form class="location" data-form="address" aria-label="Address bar" {
        @if url.is_empty() || s.private() {(icon(if s.private(){"shield"}else{"search"}))}
        @else {button type="button" class="site-button" data-op="menu" data-value="site" title="Site information and settings" aria-label="Site information"{(icon(if url.starts_with("https:"){"lock"}else{"globe"}))}}
        input id="address-input" name="address" data-address-context=(format!("{}:{}",text(s.active(),"id"),text(s.active(),"url"))) value=(text(s.active(),"url")) placeholder="Search or enter URL" autocomplete="off" spellcheck="false" aria-label="Search or enter URL" role="combobox" aria-autocomplete="list" aria-expanded=((s.menu=="suggest").to_string());}}
}
/// The browser a person chose to feel at home in; it shapes the window's chrome.
pub(crate) fn style(s: &Shell) -> &str {
    match text(&s.config()["theme"], "preset") {
        p @ ("arc" | "chrome" | "safari" | "brave" | "gx" | "vivaldi") => p,
        _ => "neutrino",
    }
}
fn rail(s: &Shell, preview: bool) -> Markup {
    let horizontal = ["top", "bottom"].contains(&text(&s.config()["layout"], "tabs"));
    let bottom = text(&s.config()["layout"], "navigation") == "bottom";
    let arc = style(s) == "arc";
    let compact = flag(&s.config()["layout"], "compactRail");
    html! {aside class="workspace-rail" aria-label="Workspace" {
        div class="rail-top" {div class="traffic-clearance" data-window-drag="true"{}
            button class="icon-button" data-op="sidebar" aria-label="Hide sidebar" title="Hide sidebar (⌘B)"{(icon("sidebar"))}
            span class="rail-drag-fill" data-window-drag="true"{}
            @if arc {(rail_navigation(s))}
            @else {button class="icon-button" data-op="menu" data-value="browser" aria-label="Browser menu" title="Browser menu"{(icon("more"))}}
        }
        @if !bottom && !horizontal {(location(s))}
        @if !preview && !compact {(feedback(s))}
        @if arc && crate::features::on(s, "favorites") {(crate::views::favorites(s))}
        div class="space-heading"{strong{(if s.private(){"Private"}else{text(&s.snapshot,"spaceName")})}button class="icon-button" data-op="menu" data-value="space" aria-label="Space options" title="Space options"{(icon("more"))}}
        @if horizontal {div class="horizontal-guide"{button class="new-tab" data-op="newTab"{(icon("plus"))"New tab"}button class="new-tab" data-op="screen" data-value="library" data-section="archive"{(icon("folder"))"Archived tabs"}}}
        @else {div class="tabs-scroll"{(tab_groups(s,preview))}}
        @if bottom && !horizontal {div class="rail-bottom-nav"{(location(s))(rail_navigation(s))}}
        div class="rail-footer"{(crate::views::media_card(s))@for widget in array(&s.snapshot["startWidgets"]){details class="workspace-widget"{summary{(text(widget,"widgetTitle"))}p{(text(widget,"widgetBody"))}}}
            nav class="rail-dock" aria-label="Spaces and Library"{
                (destination(s,"library","Library","bookmark"))
                (spaces(s))
                @if arc {button class="icon-button" data-op="menu" data-value="browser" aria-label="Browser menu" data-tip="Menu"{(icon("more"))}}
                @else {button class="avatar" data-op="menu" data-value="profiles" data-tip=(text(&s.snapshot,"profileName")) aria-label=(format!("Profile: {}",text(&s.snapshot,"profileName"))){span{(text(&s.snapshot,"profileName").chars().next().unwrap_or('P'))}}}
            }
        }
    }}
}

fn destination(s: &Shell, screen: &str, label: &str, glyph: &str) -> Markup {
    let selected = s.screen == screen;
    html! {button class=(if selected{"icon-button selected"}else{"icon-button"}) data-op="screen" data-value=(screen) data-section=[(screen=="library").then_some("bookmarks")] data-tip=(label) aria-label=(label) aria-current=[selected.then_some("page")]{(icon(glyph))}}
}
/// An address without its scheme or trailing slash, for secondary text.
pub(crate) fn readable(url: &str) -> String {
    let trimmed = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .unwrap_or(url);
    let trimmed = trimmed.strip_prefix("www.").unwrap_or(trimmed);
    trimmed.strip_suffix('/').unwrap_or(trimmed).chars().take(160).collect()
}
pub(crate) fn host(url: &str) -> String {
    if url.is_empty() {
        "Search or enter URL".into()
    } else {
        url::Url::parse(url)
            .ok()
            .and_then(|u| {
                u.host_str()
                    .map(|h| h.trim_start_matches("www.").to_string())
            })
            .unwrap_or_else(|| url.chars().take(120).collect())
    }
}
fn vacant(s: &Shell) -> Markup {
    let wallpaper = crate::views::wallpaper_style(s);
    let page = vacant_page(s);
    let live = text(&s.snapshot["preferences"], "liveWallpaper");
    let live = (crate::features::on(s, "wallpapers") && wallpaper.is_empty() && ["aurora", "waves", "embers"].contains(&live) && crate::views::start_option(s, "wallpaper")).then_some(live);
    if let Some(live) = live {
        return html! {div class=(format!("wallpaper-start live-wallpaper live-{live}")){(page)}};
    }
    if wallpaper.is_empty() {
        return page;
    }
    html! {div class="wallpaper-start" style=(wallpaper){(page)}}
}
fn vacant_page(s: &Shell) -> Markup {
    let search = crate::views::start_option(s, "search");
    let sites = crate::views::start_option(s, "sites");
    let clock = crate::views::start_option(s, "clock");
    match style(s) {
        "arc" => html! {section class="start-page arc-empty" aria-label="New tab"{button class="arc-hint" data-op="newTab"{kbd{"⌘T"}span{"Search or open a site"}}}},
        "chrome" => html! {section class="start-page chrome-start" aria-label="New tab"{div class="start-inner"{
            (private_note(s))
            @if search {button class="start-search" data-op="newTab"{(icon("search"))span{"Search or type a URL"}}}
            @if sites {(shortcut_grid(s, 8, "shortcut"))}
        }}},
        "brave" => html! {section class="start-page brave-start" aria-label="New tab"{
            div class="brave-top"{
                @if s.snapshot["shieldsStats"].is_object() && crate::views::start_option(s, "stats") {div class="brave-stats"{
                    div{strong{(s.snapshot["shieldsStats"]["blocked"].as_u64().unwrap_or(0))}small{"Trackers & ads blocked in open tabs"}}
                }}
                span class="spacer"{}
                @if clock {time class="brave-clock" data-clock="true"{}}
            }
            div class="start-inner"{(private_note(s))@if search {button class="start-search" data-op="newTab"{(icon("search"))span{"Search the web privately"}}}@if sites {(shortcut_grid(s, 6, "shortcut"))}}
        }},
        "vivaldi" | "gx" => html! {section class="start-page speed-dial" aria-label="Start page"{div class="start-inner"{
            @if style(s) == "vivaldi" {nav class="dial-tabs" aria-label="Start page sections"{button class="selected" aria-current="page"{"Speed Dial"}button data-op="screen" data-value="library" data-section="bookmarks"{"Bookmarks"}button data-op="screen" data-value="library" data-section="history"{"History"}}}
            (private_note(s))
            @if clock {time class="dial-clock" data-clock="true"{}}
            @if search {form class="location dial-search" data-form="address" aria-label="Search"{(icon("search"))input name="address" placeholder="Search or enter an address" autocomplete="off" spellcheck="false" aria-label="Search or enter an address";}}
            @if sites {(shortcut_grid(s, 11, "dial"))}
        }}},
        "safari" => {
            let shown = crate::views::start_option(s, "sites");
            let sites = if shown { top_sites(s, 12) } else { vec![] };
            let favorites: Vec<(String, String)> = if shown { array(&s.snapshot["bookmarks"]).iter().take(12).map(|b| (text(b, "title").to_string(), text(b, "url").to_string())).collect() } else { vec![] };
            let reading: Vec<&Value> = if crate::features::on(s, "reading-list") && crate::views::start_option(s, "reading") { array(&s.snapshot["preferences"]["readingList"]).iter().filter(|i| i["profileID"] == s.snapshot["session"]["profileID"] && !flag(i, "read")).take(4).collect() } else { vec![] };
            html! {section class="start-page safari-start" aria-label="Start page"{div class="start-inner"{
                (private_note(s))
                @if !favorites.is_empty() {section class="start-section"{h2{"Favorites"}div class="safari-grid"{@for (title, url) in &favorites {(site_tile(title, url, "favorite"))}}}}
                @if !sites.is_empty() {section class="start-section"{h2{"Frequently Visited"}div class="safari-grid"{@for (title, url) in &sites {(site_tile(title, url, "favorite"))}}}}
                @if crate::views::start_option(s, "stats") {section class="start-section"{h2{"Privacy Report"}div class="privacy-report"{(icon("shield"))p{(if flag(&s.snapshot["preferences"],"blockTrackers"){"Known trackers are blocked on the sites you visit."}else{"Tracker blocking is off. Turn it on in Settings → Privacy."})}}}}
                @if !reading.is_empty() {section class="start-section"{h2{"Reading List"}div class="safari-reading"{@for i in &reading {button class="safari-reading-item" data-op="navigate" data-value=(text(i,"url")){(site(i))span{strong{(text(i,"title"))}small{(host(text(i,"url")))}}}}}}}
                @if shown && favorites.is_empty() && sites.is_empty() {p class="start-empty"{"Sites you bookmark and visit often will appear here."}}
            }}}
        }
        _ => {
            let guide = !s.private() && !flag(&s.snapshot["preferences"], "startGuideHidden");
            html! {section class="start-page minimal-start" aria-label="New tab" {div class="start-inner"{
                (private_note(s))
                @if search {button class="start-search" data-op="newTab" {(icon("search"))span{"Search or enter an address"}kbd{"⌘T"}}}
                @if guide {(start_guide(s))}
            }}}
        }
    }
}
fn private_note(s: &Shell) -> Markup {
    html! {@if s.private(){p class="start-private"{(icon("shield"))"Private window. History, cookies and site data from this window are erased when you close it."}}}
}
/// Sites for start-page tiles: bookmarks, then the pages visited most recently.
fn top_sites(s: &Shell, limit: usize) -> Vec<(String, String)> {
    let mut seen = std::collections::HashSet::new();
    let mut sites = vec![];
    for entry in array(&s.snapshot["bookmarks"]).iter().chain(array(&s.snapshot["history"])).chain(s.tabs().iter().filter(|t| flag(t, "pinned"))) {
        let url = text(entry, "url");
        if url.is_empty() || !seen.insert(host(url)) {
            continue;
        }
        sites.push((text(entry, "title").to_string(), url.to_string()));
        if sites.len() == limit {
            break;
        }
    }
    sites
}
fn site_tile(title: &str, url: &str, class: &str) -> Markup {
    let mark = json!({"url": url});
    html! {button class=(format!("site-tile {class}")) data-op="navigate" data-value=(url) title=(url){span class="tile-mark"{(site(&mark))}span class="tile-title"{(if title.is_empty() {host(url)} else {title.to_string()})}}}
}
fn shortcut_grid(s: &Shell, limit: usize, class: &str) -> Markup {
    let dial = crate::views::speed_dial(s);
    let sites = if dial.is_empty() { top_sites(s, limit) } else { vec![] };
    html! {div class=(format!("shortcut-grid {class}-grid")){
        @for (title, url, id) in dial.iter().take(limit) {div class="dial-entry" data-dial=(id){(site_tile(title, url, class))button class="icon-button dial-edit" data-op="menu" data-value=(format!("edit-bookmark:{id}")) aria-label=(format!("Edit {title}")){(icon("edit"))}}}
        @for (title, url) in &sites {(site_tile(title, url, class))}
        @if !s.private() && (class == "favorite" || crate::features::on(s, "speed-dial")) {button class=(format!("site-tile {class} add-tile")) data-op="menu" data-value=(if class=="favorite" {"add-site"} else {"add-site:dial"}) title="Add a site"{span class="tile-mark"{span class="site-icon blank-icon"{(icon("plus"))}}span class="tile-title"{"Add"}}}
    }}
}
fn start_guide(s: &Shell) -> Markup {
    let profile = &s.snapshot["session"]["profileID"];
    let spaces = array(&s.snapshot["spaces"]).iter().filter(|v| v["profileID"] == *profile).count();
    let steps: [(&str, &str, bool, Markup); 4] = [
        ("Import your bookmarks", "Use an HTML export from Chrome, Safari, Firefox or Arc.",
            !array(&s.snapshot["bookmarks"]).is_empty() || flag(&s.snapshot, "imported"),
            html! {button class="button" data-op="importBookmarks"{"Import…"}}),
        ("Pin the sites you use every day", "Right-click a tab and choose Pin tab, or drag it above your other tabs.",
            s.tabs().iter().any(|t| flag(t, "pinned")), html! {}),
        ("Make a Space for a project", "Spaces keep separate sets of tabs. Switch between them at the bottom of the sidebar.",
            spaces > 1, html! {button class="button" data-op="menu" data-value="new-space"{"New Space"}}),
        ("Set Neutrino as your default browser", "Links you open in other apps will open here.",
            flag(&s.snapshot, "isDefaultBrowser"), html! {button class="button" data-op="defaultBrowser"{"Set as default"}}),
    ];
    let done = steps.iter().filter(|step| step.2).count();
    html! {@if done < steps.len() {details class="start-guide"{
        summary{span class="guide-title"{"Get set up"}span class="guide-progress" role="progressbar" aria-valuemin="0" aria-valuemax=(steps.len()) aria-valuenow=(done) aria-label="Setup progress"{span style=(format!("--progress:{}",done as f64/steps.len() as f64)){}}small{(done)" of "(steps.len())}(icon("down"))}
        div class="guide-hide"{button class="button quiet" data-op="preference" data-key="startGuideHidden" data-value="true" data-type="bool"{"Don’t show again"}}
        ol{@for (title,detail,complete,action) in steps {li class=(if complete{"done"}else{""}){span class="guide-check" aria-hidden="true"{@if complete{(icon("check"))}}div{strong{(title)}@if !complete{small{(detail)}}}@if !complete{(action)}}}}
        div class="guide-keys" aria-label="Keyboard shortcuts"{span{kbd{"⌘T"}"New tab"}span{kbd{"⌘K"}"Switch tabs"}span{kbd{"⌘L"}"Edit address"}span{kbd{"⌘D"}"Bookmark"}span{kbd{"⌘B"}"Sidebar"}}
    }}}
}
pub(crate) fn module_tools(s: &Shell) -> Markup {
    let blank = text(s.active(), "url").is_empty();
    html! {div class="module-tools" role="group" aria-label="Page tools" {
        @for m in array(&s.snapshot["modules"]).iter().filter(|m|flag(m,"enabled")) {
            @match text(m,"capability") {
                "notes" => {button class="icon-button" data-op="panel" data-value="notes" title="Notes beside this page" aria-label="Notes beside this page"{(icon("edit"))}}
                "reader" => {button class="icon-button" data-op="reader" title=(if blank{"Reader: open a page to read it"}else{"Read this page"}) aria-label="Read this page" disabled[blank]{(icon("book"))}}
                "screenshot" => {button class="icon-button" data-op="capture" title=(if blank{"Capture: open a page to capture it"}else{"Capture this page"}) aria-label="Capture this page" disabled[blank]{(icon("camera"))}}
                "resourceMonitor" | "memoryMonitor" => {button class="icon-button" data-op="panel" data-value="resources" title=(text(m,"name")) aria-label=(text(m,"name")){(icon("activity"))}}
                _ => {}
            }
        }
    }}
}
fn workspace_panel(s: &Shell, key: &str) -> Markup {
    if key.starts_with("web:") {
        if !crate::features::on(s, "web-panels") {
            return html! {};
        }
        return crate::views::web_panel(s, key);
    }
    if key == "safari" {
        return safari_sidebar(s);
    }
    if key == "feeds" {
        return html! {aside class="workspace-panel" aria-label="Feeds"{header{h2{"Feeds"}button class="icon-button" data-op="panel" data-value="" aria-label="Close panel"{(icon("close"))}}(crate::views::feeds_panel(s))}};
    }
    let mut copy = s.clone();
    copy.section = key.into();
    copy.panel = key.into();
    html! {aside class="workspace-panel" aria-label=(key) {header{h2{(match key{"notes"=>"Notes","history"=>"History","downloads"=>"Downloads","resources"=>if style(s)=="gx"{"Resource control"}else{"Resources"},"tabs"=>"Window",_=>"Bookmarks"})}button class="icon-button" data-op="panel" data-value="" aria-label="Close panel"{(icon("close"))}}
        @if key=="resources" {(resources(s))@if style(s)=="gx" {(crate::views::gx_control(s))}}@else if key=="tabs" {div class="tabs-scroll window-panel"{(tab_groups(s,false))}}@else{(library(&copy))}
    }}
}

fn page_actions(s: &Shell, style: &str) -> Markup {
    let blank = text(s.active(), "url").is_empty();
    let inline = text(&s.config()["layout"], "pageTools") == "toolbar";
    let focus = flag(&s.snapshot, "focusMode");
    let items: Vec<&str> = array(&s.config()["layout"]["toolbarItems"]).iter().filter_map(Value::as_str).collect();
    html! {div class="page-actions"{
        @if inline {(module_tools(s))}
        @for item in items {(toolbar_item(s, item, blank))}
        @if focus {button class="button focus-exit" data-op="native" data-action="toggleFocus" aria-label="Exit Focus mode"{(icon("focus"))"Exit Focus"}}
        @if !["chrome", "brave", "safari"].contains(&style) {(bookmark_button(s))}
        @if style == "safari" {button class="icon-button" data-op="newTab" title="New tab (⌘T)" aria-label="New tab"{(icon("plus"))}}
        button class="icon-button" data-op="menu" data-value="page" title=(if blank {"Page options: open a page first"} else {"Page options"}) aria-label="Page options"{(icon("more"))}
        @if ["chrome", "brave", "gx"].contains(&style) {
            button class="avatar" data-op="menu" data-value="profiles" title=(text(&s.snapshot,"profileName")) aria-label=(format!("Profile: {}",text(&s.snapshot,"profileName"))){span{(text(&s.snapshot,"profileName").chars().next().unwrap_or('P'))}}
            button class="icon-button" data-op="menu" data-value="browser" title="Browser menu" aria-label="Browser menu"{(icon("kebab"))}
        }
        @if style == "vivaldi" {button class="icon-button" data-op="menu" data-value="browser" title="Vivaldi-style menu" aria-label="Browser menu"{(icon("menu"))}}
    }}
}
/// Safari's sidebar: Tab Groups (Spaces), then Bookmarks and Reading List,
/// with the rest of the browser one click away.
fn safari_sidebar(s: &Shell) -> Markup {
    let spaces: Vec<&Value> = array(&s.snapshot["spaces"]).iter().filter(|v| v["profileID"] == s.snapshot["session"]["profileID"]).collect();
    let reading = crate::features::on(s, "reading-list");
    html! {aside class="workspace-panel safari-sidebar" aria-label="Sidebar" {
        nav class="safari-sidebar-list" {
            @if !s.private() {
                div class="safari-sidebar-label"{"Tab Groups"}
                @for space in &spaces {
                    @let current = space["id"] == s.snapshot["session"]["spaceID"];
                    button class=(if current {"safari-row selected"} else {"safari-row"}) data-op="switchSpace" data-id=(text(space, "id")) aria-pressed=(current.to_string()){(icon("folder"))span{(text(space, "name"))}@if current {span class="safari-count"{(s.tabs().len())}}}
                }
                button class="safari-row quiet" data-op="menu" data-value="new-space"{(icon("plus"))span{"New Tab Group"}}
            }
            div class="safari-sidebar-label"{"Library"}
            button class="safari-row" data-op="screen" data-value="library" data-section="bookmarks"{(icon("bookmark"))span{"Bookmarks"}}
            @if reading {button class="safari-row" data-op="screen" data-value="library" data-section="reading"{(icon("book"))span{"Reading List"}}}
            button class="safari-row" data-op="screen" data-value="library" data-section="history"{(icon("history"))span{"History"}}
            button class="safari-row" data-op="screen" data-value="library" data-section="downloads"{(icon("download"))span{"Downloads"}}
        }
        footer class="safari-sidebar-footer"{
            button class="safari-row" data-op="menu" data-value="browser"{(icon("menu"))span{"More…"}}
            button class="safari-row" data-op="screen" data-value="settings"{(icon("settings"))span{"Settings"}}
        }
    }}
}
/// Optional toolbar buttons chosen in Customize.
pub(crate) const TOOLBAR_ITEMS: &[(&str, &str, &str)] = &[
    ("home", "Start page", "home"), ("reader", "Reader view", "reader"), ("capture", "Capture", "camera"),
    ("split", "Split view", "split"), ("downloads", "Downloads", "download"), ("history", "History", "history"),
    ("bookmarks", "Bookmarks", "bookmark"), ("reading", "Reading List", "book"), ("share", "Share", "external"),
    ("print", "Print", "print"), ("pip", "Picture in picture", "pip"), ("extensions", "Extensions", "plug"),
    ("notes", "Notes", "edit"), ("panels", "Panels", "panel"),
];
fn toolbar_item(s: &Shell, item: &str, blank: bool) -> Markup {
    let Some((_, label, glyph)) = TOOLBAR_ITEMS.iter().find(|t| t.0 == item) else { return html! {} };
    let (op, value, needs_page) = match item {
        "home" => ("home", "", false),
        "reader" => ("reader", "", true),
        "capture" => ("menu", "capture", true),
        "split" => ("menu", "split-choose", true),
        "downloads" | "history" | "bookmarks" => ("panel", item, false),
        "reading" => ("screen", "library", false),
        "share" | "print" | "pip" => ("page-command", item, true),
        "extensions" => ("screen", "extensions", false),
        "notes" => ("panel", "notes", false),
        _ => ("panel-toggle", "", false),
    };
    let _ = s;
    html! {button class="icon-button" data-op=(op) data-value=[(!value.is_empty()).then_some(value)] data-section=[(item=="reading").then_some("reading")] title=(label) aria-label=(label) disabled[needs_page && blank]{(icon(glyph))}}
}
fn bookmark_button(s: &Shell) -> Markup {
    let saved = array(&s.snapshot["bookmarks"]).iter().any(|b| b["url"] == s.active()["url"] && !text(s.active(), "url").is_empty());
    html! {button class=(if saved {"icon-button saved"} else {"icon-button"}) data-op="bookmark" title=(if s.private(){"Bookmarks aren’t saved in private windows"}else if text(s.active(),"url").is_empty(){"Bookmark: open a page to save it"}else if saved {"Bookmarked (⌘D)"} else {"Bookmark this page (⌘D)"}) aria-label="Save bookmark" aria-pressed=(saved.to_string()) disabled[s.private() || text(s.active(),"url").is_empty()]{(icon("bookmark"))}}
}
/// Address field for top-tab layouts, with each browser's in-field controls.
fn address(s: &Shell, style: &str) -> Markup {
    let shields = flag(&s.snapshot["preferences"], "blockTrackers") && !shields_lowered(s);
    html! {
        div class="address-group" {
            (location(s))
            @if ["chrome", "brave", "safari"].contains(&style) {(bookmark_button(s))}
            @if style == "brave" {
                @let count = s.snapshot["blockedCount"].as_u64().filter(|n| *n > 0 && shields);
                button class=(if shields {"shields-button on"} else {"shields-button"}) data-op="menu" data-value="shields" title=(if shields {"Shields are up for this site"} else {"Shields are down for this site"}) aria-label=(match count {Some(n) => format!("Shields: {n} blocked on this page"), None => "Shields".into()}){(icon("shield"))@if let Some(n) = count {span class="shield-count"{(if n > 99 {"99+".to_string()} else {n.to_string()})}}}
            }
        }
        @if style == "vivaldi" {form class="location search-field" data-form="address" aria-label="Search"{(icon("search"))input name="address" placeholder=(format!("Search {}",match text(&s.snapshot["preferences"],"search"){"google"=>"Google","bing"=>"Bing",_=>"DuckDuckGo"})) autocomplete="off" spellcheck="false" aria-label="Search the web";}}
    }
}
pub(crate) fn shields_lowered(s: &Shell) -> bool {
    let site = host(text(s.active(), "url"));
    array(&s.snapshot["preferences"]["shieldsDown"]).iter().any(|h| h.as_str() == Some(site.as_str()))
}
fn toolbar(s: &Shell, style: &str, horizontal: bool, panel: bool) -> Markup {
    let lead = horizontal && (style == "safari" || text(&s.config()["layout"], "tabs") == "bottom");
    html! {header class="page-toolbar" {
        @if lead {div class="traffic-clearance" data-window-drag="true"{}}
        @if horizontal && style == "vivaldi" {(button("Panel", "panel-toggle", "sidebar"))}
        @if horizontal && style == "safari" {
            @let open = s.visible_panel_key() == "safari";
            button class=(if open {"icon-button selected"} else {"icon-button"}) data-op="panel" data-value="safari" title=(if open {"Hide sidebar"} else {"Show sidebar"}) aria-label=(if open {"Hide sidebar"} else {"Show sidebar"}) aria-pressed=(open.to_string()){(icon("sidebar"))}
        }
        div class="toolbar-controls"{(rail_navigation(s))@if style == "vivaldi" {(button("Start page","home","home"))}}
        @if !horizontal && (s.sidebar_hidden || panel) { (button(if panel{"Return to tabs"}else{"Show sidebar"},if panel{"reveal-workspace"}else{"sidebar"},"sidebar")) }
        span class="toolbar-drag" data-window-drag="true"{}
        @if horizontal {(address(s, style))}
        @else {button class="page-identity" data-op="focus-address" title=(text(s.active(),"url")){(icon(if text(s.active(),"url").starts_with("https:"){"lock"}else{"globe"}))span{(if text(s.active(),"url").is_empty(){"New Tab".into()}else{host(text(s.active(),"url"))})}}}
        span class="toolbar-drag" data-window-drag="true"{}
        (page_actions(s, style))
    }}
}
/// The narrow strip of panel buttons used by Opera GX and Vivaldi.
fn panel_strip(s: &Shell) -> Markup {
    let style = style(s);
    let open = s.visible_panel_key();
    let items: Vec<&str> = if array(&s.config()["layout"]["panelItems"]).is_empty() {
        if style == "gx" { vec!["control", "bookmarks", "history", "downloads", "notes"] } else { vec!["bookmarks", "downloads", "history", "notes", "feeds", "tabs"] }
    } else {
        array(&s.config()["layout"]["panelItems"]).iter().filter_map(Value::as_str).collect()
    };
    html! {nav class="panel-strip" aria-label="Panels" {
        @if style == "gx" {(workspace_button(s, true))}
        @for item in items {
            @let (key, label, glyph) = match item {
                "control" => ("resources", "Resource control", "activity"),
                "bookmarks" => ("bookmarks", "Bookmarks", "bookmark"),
                "history" => ("history", "History", "history"),
                "downloads" => ("downloads", "Downloads", "download"),
                "notes" => ("notes", "Notes", "edit"),
                "tabs" => ("tabs", "Window", "sidebar"),
                "feeds" if crate::features::on(s, "feeds") => ("feeds", "Feeds", "feed"),
                _ => ("", "", ""),
            };
            @if !key.is_empty() {button class=(if open == key {"strip-button selected"} else {"strip-button"}) data-op="panel" data-value=(if open == key {""} else {key}) data-tip=(label) aria-label=(label) aria-pressed=((open == key).to_string()){(icon(glyph))}}
        }
        @if !s.private() {span class="strip-divider"{}(crate::views::web_panel_buttons(s))}
        span class="spacer"{}
        button class="strip-button" data-op="screen" data-value="settings" data-tip="Settings" aria-label="Settings"{(icon("settings"))}
    }}
}
/// Spaces as a compact switcher for layouts without a sidebar.
fn workspace_button(s: &Shell, compact: bool) -> Markup {
    let name = if s.private() { "Private" } else { text(&s.snapshot, "spaceName") };
    html! {button class=(if compact {"strip-button workspace-switch"} else {"workspace-switch"}) data-op="menu" data-value="workspaces" title=(format!("Space: {name}")) aria-label=(format!("Space: {name}. Switch Space")) disabled[s.private()]{
        span class="space-symbol" data-tone=[space_tone(s)]{(name.chars().next().unwrap_or('S'))}
        @if !compact {span{(name)}(icon("down"))}
    }}
}
pub(crate) fn space_tone(s: &Shell) -> Option<usize> {
    array(&s.snapshot["spaces"])
        .iter()
        .filter(|v| v["profileID"] == s.snapshot["session"]["profileID"])
        .position(|v| v["id"] == s.snapshot["session"]["spaceID"])
        .map(|index| index % 5)
}
/// Vivaldi's status bar: panel toggle, page tools, zoom and a clock.
fn status_bar(s: &Shell) -> Markup {
    let blank = text(s.active(), "url").is_empty();
    let zoom = (s.snapshot["zoom"].as_f64().unwrap_or(1.) * 100.).round();
    html! {footer class="status-bar" {
        (button("Toggle panel", "panel-toggle", "sidebar"))
        span class="status-text"{(if blank {"New Tab".to_string()} else {readable(text(s.active(), "url"))})}
        span class="spacer"{}
        span class="status-count" title="Tabs in this window"{(s.tabs().len())(if s.tabs().len() == 1 {" tab"} else {" tabs"})}
        @if crate::features::on(s, "page-styles") {button class="status-button" data-op="menu" data-value="page-style" disabled[blank] title="Page actions"{(icon("appearance"))}}
        button class="status-button" data-op="menu" data-value="split-choose" disabled[blank] title="Tile tabs"{(icon("split"))}
        button class="status-button" data-op="capture" disabled[blank] title="Capture page"{(icon("camera"))}
        button class="status-button" data-op="reader" disabled[blank] title="Reader view"{(icon("reader"))}
        div class="zoom-control" role="group" aria-label="Page zoom" {
            button class="status-button" data-op="zoom-step" data-value="-1" disabled[blank] aria-label="Zoom out"{"−"}
            input class="zoom-slider" type="range" min="50" max="300" step="10" value=(zoom) disabled[blank] aria-label="Page zoom" data-zoom-slider="true";
            button class="status-zoom" data-op="zoom-step" data-value="0" disabled[blank] title="Reset zoom"{(zoom)"%"}
            button class="status-button" data-op="zoom-step" data-value="1" disabled[blank] aria-label="Zoom in"{"+"}
        }
        time class="status-clock" data-clock="true"{}
    }}
}
fn horizontal_tabs(s: &Shell, preview: bool) -> Markup {
    let stacks = style(s) == "vivaldi" && crate::features::on(s, "tab-stacks");
    let islands = style(s) == "gx" && crate::features::on(s, "tab-islands");
    html! {div class="horizontal-tabs" {
        div class="tab-strip-lead" data-window-drag="true" {@if style(s) != "safari" && text(&s.config()["layout"],"tabs") != "bottom" {div class="traffic-clearance"{}}@if !s.private() {(workspace_button(s, false))}}
        // Only the tabs scroll; the Space switcher and New tab stay in view however many tabs are open.
        div class="horizontal-tab-scroll" {
        div class="horizontal-group" data-drop-group="pinned" {
            span class="horizontal-group-label" title="Pinned tabs"{(icon("pin"))}
            @for t in s.tabs().iter().filter(|t|flag(t,"pinned")&&tab_visible(t,s)){(tab_row(t,s,preview))}
        }
        @for folder in array(&s.snapshot["folders"]) {
            @let members: Vec<&Value> = s.tabs().iter().filter(|t|!flag(t,"pinned")&&t["folderID"]==folder["id"]).collect();
            @if stacks {
                @let active = members.iter().any(|t| t["id"] == s.active()["id"]);
                div class=(if active {"tab-row stack-tab active"} else {"tab-row stack-tab"}) data-drop-group="folder" data-folder=(text(folder,"id")) data-color=[(!text(folder,"color").is_empty()).then(||text(folder,"color"))] {
                    button class="tab-select" data-op="selectTab" data-id=(members.first().map(|t|text(t,"id")).unwrap_or("")) disabled[members.is_empty()] title=(format!("Stack: {}",text(folder,"name"))){(icon("folder"))span{(text(folder,"name"))}span class="stack-count"{(members.len())}}
                    button class="tab-menu" data-op="menu" data-value=(format!("folder:{}",text(folder,"id"))) aria-label=(format!("Options for {}",text(folder,"name"))){(icon("more"))}
                }
            } @else {
            div class="horizontal-group" data-drop-group="folder" data-folder=(text(folder,"id")) data-color=[(!text(folder,"color").is_empty()).then(||text(folder,"color"))] {
                button class="horizontal-group-label" data-op="toggleFolder" data-id=(text(folder,"id")) aria-expanded=((!flag(folder,"collapsed")).to_string()){(icon("folder"))(text(folder,"name"))}
                button class="icon-button folder-options" data-op="menu" data-value=(format!("folder:{}",text(folder,"id"))) aria-label=(format!("Options for {}",text(folder,"name"))){(icon("more"))}
                @if !flag(folder,"collapsed") {@for t in members {(tab_row(t,s,preview))}}
            }
            }
        }
        div class="horizontal-group" data-drop-group="today" {
            @let loose: Vec<&Value> = s.tabs().iter().filter(|t|!flag(t,"pinned")&&text(t,"folderID").is_empty()&&tab_visible(t,s)).collect();
            @if islands {(crate::views::islands(s, &loose, preview))} @else {@for t in loose {(tab_row(t,s,preview))}}
        }
        }
        (button("New tab","newTab","plus"))
        div class="strip-spacer" data-window-drag="true" data-drop-group="today" {}
    }
    @if stacks {(crate::views::stack_row(s, preview))}
    }
}

fn browser(s: &Shell, preview: bool) -> Markup {
    let placement = text(&s.config()["layout"], "tabs");
    let horizontal = ["top", "bottom"].contains(&placement);
    let panel_key = s.visible_panel_key();
    let panel = !panel_key.is_empty() || preview && s.edit_component == "panels";
    let width = s.config()["layout"]["tabsWidth"]
        .as_f64()
        .unwrap_or(240.)
        .clamp(200., 340.);
    let tone = space_tone(s);
    let style = style(s);
    let strip = flag(&s.config()["layout"], "panelBar");
    let status = flag(&s.config()["layout"], "statusBar");
    let gradient: Vec<&str> = array(&s.snapshot["spaces"]).iter().find(|v| v["id"] == s.snapshot["session"]["spaceID"]).map(|v| array(&v["gradient"]).iter().filter_map(Value::as_str).filter(|h| crate::appearance::hex(h)).collect()).unwrap_or_default();
    let space_style = if gradient.len() == 2 && !s.private() { format!(";--space-from:{};--space-to:{}", gradient[0], gradient[1]) } else { String::new() };
    let compact = flag(&s.config()["layout"], "compactRail") && !horizontal;
    let width = if compact { 64. } else { width };
    html! {div class=(format!("browser-shell style-{style} placement-{} {} {} {} {}{}{}",placement,if panel{"with-panel"}else{""},if s.sidebar_hidden{"rail-hidden"}else{""},if preview{"editing-preview"}else{""},if strip{"with-strip"}else{""},if s.rail_peek && !preview {" rail-peek"}else{""},if compact {" compact-rail"} else {""})) style=(format!("--rail-width:{width}px;--panel-width:{}px{space_style}",s.config()["layout"]["sidebarWidth"].as_f64().unwrap_or(300.))) data-navigation=(text(&s.config()["layout"],"navigation")) data-panel=(if strip {"leading"} else {text(&s.config()["layout"],"sidebar")}) data-tone=[(!s.private()).then_some(tone).flatten()] data-gradient=[(!space_style.is_empty()).then_some("true")] {
        div class="window-grip" data-window-drag="true"{}
        @if !horizontal || preview {(rail(s,preview))}
        @if s.sidebar_hidden && !horizontal && !preview {div class="rail-edge" data-rail-edge="true" aria-hidden="true"{}}

        @if !horizontal && !s.sidebar_hidden && !compact {div class="rail-resizer" role="separator" tabindex="0" aria-label="Sidebar width" aria-orientation="vertical" aria-valuemin="200" aria-valuemax="340" aria-valuenow=(width) data-resize="rail" {}}
        main class="browser-main" {
        @if horizontal && placement=="top" && style != "safari" {(horizontal_tabs(s,preview))}
        @if style != "arc" || s.sidebar_hidden || horizontal {(toolbar(s, style, horizontal, panel))}
        @if horizontal && placement=="top" && style == "safari" {(horizontal_tabs(s,preview))}
        @if (s.sidebar_hidden || horizontal || compact) && !preview {(feedback(s))}
        @if flag(&s.config()["layout"],"bookmarksBar") && !s.private() {(crate::views::bookmarks_bar(s))}
        @if !preview {(crate::views::find_bar(s))}
        div class="page-workspace"{@if strip {(panel_strip(s))}div class=(if s.snapshot["passwordPrompt"].is_object() && !preview {"page-frame with-prompt"} else {"page-frame"}){@if !preview {(crate::views::password_prompt(s))}
            @if !preview && !["browse","editor"].contains(&s.screen.as_str()) {(utility_page(s))}
            @else if !s.snapshot["session"]["split"].is_null(){div class="split-canvas" data-axis=(text(&s.config()["layout"],"split")) style=(format!("--split:{}",s.config()["layout"]["splitRatio"].as_f64().unwrap_or(0.5).clamp(0.2,0.8))){
                @for (pane, id) in [&s.snapshot["session"]["split"]["first"],&s.snapshot["session"]["split"]["second"]].into_iter().enumerate() {
                    @if pane == 1 && !preview {div class="split-divider" role="separator" aria-label="Resize split view" aria-orientation=(if text(&s.config()["layout"],"split")=="stacked"{"horizontal"}else{"vertical"}){}}
                    @let identifier=id.as_str().unwrap_or("");
                    section class="split-pane" {div class="split-label"{button data-op="selectTab" data-id=(identifier){(s.tabs().iter().find(|t|t["id"]==*id).map(|t|text(t,"title")).unwrap_or("New tab"))}(button("Exit split view","unsplit","close"))}
                        @if let Some(error)=s.snapshot["pageErrors"][identifier].as_str(){(page_error(error,identifier))}
                        @else {div class="native-page" data-page=(identifier){(page_backdrop(s,identifier))@if preview {div class="preview-webpage"{p{"Your page"}}}}}
                    }
                }
            }} @else if let Some(message)=s.snapshot["pageError"].as_str(){(page_error(message,text(s.active(),"id")))}
            @else if !text(s.active(),"url").is_empty() {div class="native-page" data-page=(text(s.active(),"id")){(page_backdrop(s,text(s.active(),"id")))@if preview {div class="preview-webpage"{p{"Your page"}small{(host(text(s.active(),"url")))}}}}}
            @else {(vacant(s))}
            @if !preview {(crate::views::capture_overlay(s))}
        }
        @if panel {(workspace_panel(s,if panel_key.is_empty(){"bookmarks"}else{panel_key}))}}
        @if horizontal && placement=="bottom"{(horizontal_tabs(s,preview))}
        @if status {(status_bar(s))}
        }
        @if !preview {(crate::views::break_overlay(s))}
    }}
}

fn page_backdrop(s: &Shell, id: &str) -> Markup {
    let image = s.snapshot["pageBackdrops"][id].as_str().unwrap_or("");
    html! {@if (s.palette || !s.menu.is_empty()) && image.starts_with("data:image/png;base64,") && image.len()<=2_100_000 {img class="page-backdrop" src=(image) alt="" aria-hidden="true";}}
}

fn page_error(message: &str, id: &str) -> Markup {
    html! {div class="page-error"{(icon("globe"))h2{"This page couldn’t open"}p{(message)}div class="button-row"{button class="button primary" data-op="native" data-action="reloadTab" data-id=(id){"Try again"}button class="button" data-op="native" data-action="useWebKit" data-id=(id){"Try WebKit"}}}}
}

fn sound_flags(s: &Shell) -> String {
    if !crate::features::on(s, "sounds") {
        return String::new();
    }
    let p = &s.snapshot["preferences"];
    let gx = style(s) == "gx";
    let mut out = vec![];
    if p["interfaceSounds"].as_bool().unwrap_or(gx && flag(&s.config()["theme"], "sounds")) {
        out.push("ui");
    }
    if flag(p, "keyboardSounds") {
        out.push("keys");
    }
    if flag(p, "backgroundMusic") && !(flag(p, "batterySaver") && flag(&s.snapshot, "onBattery")) {
        out.push("music");
    }
    out.join(" ")
}
fn schedule(s: &Shell) -> Option<String> {
    if !crate::features::on(s, "theme-schedule") {
        return None;
    }
    let t = &s.snapshot["preferences"]["themeSchedule"];
    (flag(t, "enabled") && !s.onboarding()).then(|| format!("{}-{}", text(t, "light"), text(t, "dark")))
}
pub fn render(s: &Shell) -> Markup {
    let mode = if s.onboarding() {
        text(&s.setup, "appearance")
    } else {
        text(&s.config()["theme"], "colorMode")
    };
    let accent = if s.onboarding() {
        text(&s.setup, "accent")
    } else {
        text(&s.config()["theme"], "accent")
    };
    html! {div class="app-shell" style=(theme_style(s)) data-icons=(text(&s.config()["theme"],"iconPack")) data-preset=(if s.onboarding(){text(&s.setup,"preset")}else{text(&s.config()["theme"],"preset")}) data-design=(text(&s.config()["theme"],"design")) data-transparency=(flag(&s.config()["theme"],"transparency").to_string()) data-typeface=(text(&s.config()["theme"],"typography")) data-focus=(flag(&s.snapshot,"focusMode").to_string()) data-focus-hidden=(array(&s.snapshot["focusHidden"]).iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" ")) data-mode=(mode) data-accent=(accent) data-density=(text(&s.config()["theme"],"density")) data-reduced-motion=(flag(&s.config()["theme"],"reducedMotion").to_string()) data-sounds=(sound_flags(s)) data-schedule=[schedule(s)] {
        (icon_definitions(s))@if flag(&s.snapshot,"downloadsWindow"){main class="downloads-window"{header{h1{"Downloads"}(button("Close downloads","escape","close"))}(library(s))}} @else if s.onboarding(){(setup(s))} @else if s.screen=="editor"{(editor(s))} @else {(browser(s,false))
        }
        @if s.palette{(palette(s))}
        @if !s.menu.is_empty(){(menu(s))}
        @if let Some(css) = crate::views::interface_css(s) {style class="interface-css"{(PreEscaped(css))}}

    }}
}
pub(crate) fn feedback(s: &Shell) -> Markup {
    let notice = if !text(&s.snapshot, "notice").is_empty() {
        text(&s.snapshot, "notice")
    } else {
        s.notice.as_str()
    };
    html! {@if !notice.is_empty(){div class="rail-feedback" role="status" data-transient=((notice.starts_with("Tab moved.") || notice.ends_with("order updated.")).to_string()){span{(notice)}@if notice.starts_with("Tab moved.") || notice.ends_with("order updated."){button data-op="undo-tabs"{"Undo"}}button class="icon-button" data-op="dismiss-notice" aria-label="Dismiss message"{(icon("close"))}}}}
}
fn utility_page(s: &Shell) -> Markup {
    html! {section class="utility-screen" data-screen=(s.screen.as_str()) aria-label=(s.screen.as_str()){
        header class="utility-header"{h1{(match s.screen.as_str(){"settings"=>"Settings","library"=>"Library","modules"=>"Modules","extensions"=>"Extensions","assistant"=>"Assistant","reader"=>"Reader","resources"=>"Resources","source"=>"Page source",_=>"Recovery"})}span class="spacer"{}@if s.screen=="reader" {(crate::views::reader_controls(s))}button class="button quiet" data-op="escape"{(icon("back"))"Back to browsing"}}
        (utility(s))
    }}
}
fn setup(s: &Shell) -> Markup {
    let flow = crate::appearance::setup_flow(text(&s.setup, "preset"));
    if s.step > 0 && flow.len() > 1 && flow[0] == "layout" && flow[1] != "workspace" {
        return crate::onboarding::render(s);
    }
    let last = s.step + 1 >= flow.len();
    let titles = [
        "Start somewhere familiar",
        "Set up your workspace",
        "Import your bookmarks",
        "Choose your appearance",
        "Set your defaults",
        "Choose your modules",
        "Connect AI, if you want",
        "Ready to browse",
    ];
    let descriptions = [
        "Pick the browser you know. Setup and the browser itself will then work the way that one does.",
        "Profiles separate website accounts. Spaces organize your tabs within a Profile.",
        "Choose an HTML bookmarks export. You can skip this step.",
        "Start with a layout and color. Customize either later.",
        "Choose your search engine and privacy defaults.",
        "Each feature is a module. Turn on the ones you want; change them any time in Modules.",
        "Use an API key, an OpenAI account or a local model.",
        "Review your choices and open Neutrino.",
    ];
    html! {main class=(format!("onboarding step-{}",s.step)) {
        div class="setup-drag" data-window-drag="true"{}
        aside class="setup-scene" aria-hidden="true" {div class="scene-caption"{span{(["Your browser","Profiles & Spaces","Bookmarks","Appearance","Privacy","Modules","Optional AI","All set"][s.step.min(7)])}}
            div class="mini-browser" data-layout=(text(&s.setup,"layout")){div class="mini-rail"{div class="mini-dots"{i{}i{}i{}}div class="mini-address"{(icon("search"))"Search or enter URL"}strong{(text(&s.setup,"space"))}div class="mini-pin"{i class="site-icon site-color-0"{"G"}"GitHub"}div class="mini-folder"{(icon("folder"))"Projects"}div class="mini-tab"{i class="site-icon site-color-3"{"M"}"Mail"}div class="mini-tab selected"{i class="site-icon blank-icon"{(icon("plus"))}"New Tab"}div class="mini-plus"{(icon("plus"))"New tab"}}div class="mini-page"{div class="mini-start"{div class="mini-search"{(icon("search"))"Search or enter an address"}div class="mini-tiles"{@for (label,tone) in [("GitHub",0),("Calendar",1),("Docs",2),("Mail",3)]{span class="mini-tile"{i class=(format!("site-icon site-color-{tone}")){(label.chars().next().unwrap_or('N'))}(label)}}}}}}
        }
        section class="setup-content"{header class="setup-header"{span class="wordmark"{img class="brand-icon" src="neutrino.svg" alt="";"neutrino"}}
            div class="setup-copy"{h1 id="setup-heading" tabindex="-1"{(titles[s.step])}p{(descriptions[s.step])}}
            div class="setup-form"{
                @match s.step {
                    0=>{(preset_picker(s,true))}
                    1=>{(field("Profile name","profile",text(&s.setup,"profile"),s.invalid_field=="profile"))(field("Your first Space","space",text(&s.setup,"space"),s.invalid_field=="space"))}
                    2=>{button class="import-card" data-op="importBookmarks"{span class="import-symbol"{(icon("download"))}span class="import-text"{strong{(if flag(&s.snapshot,"imported"){"Bookmarks imported"}else{"Choose a bookmarks file…"})}span{"In your old browser, export bookmarks as HTML, then choose that file here."}}(icon(if flag(&s.snapshot,"imported"){"check"}else{"arrow"}))}p class="field-help"{"Passwords and website sign-ins aren’t part of a bookmarks file."}}
                    3=>{label class="control-label"{"Color"}(swatches(s,true))label class="control-label"{"Appearance"}(segments("setup-field","appearance",text(&s.setup,"appearance"),&[("system","System"),("light","Light"),("dark","Dark")]))label class="control-label"{"Tabs"}(segments("setup-field","layout",text(&s.setup,"layout"),&[("leading","In the sidebar"),("top","Along the top")]))}
                    4=>{label class="control-label"{"Search engine"}(segments("setup-field","search",text(&s.setup,"search"),&[("duckDuckGo","DuckDuckGo"),("google","Google"),("bing","Bing")]))div class="settings-group"{(toggle("Block ads & trackers","Applies to every Profile.","blockTrackers",flag(&s.setup,"blockTrackers"),true))(toggle("Block popups","Popups you open with a click still appear.","blockPopups",flag(&s.setup,"blockPopups"),true))(toggle("Reopen your tabs at launch","Private windows are never restored.","restoreSession",flag(&s.setup,"restoreSession"),true))}}
                    5=>{(crate::onboarding::module_picker(s))}
                    6=>{details class="ai-disclosure"{summary{(icon("spark"))"Set up an AI provider"(icon("down"))}(ai_form(s))}p class="field-help"{"Skip this if you don’t plan to use AI. You can add a provider later in Settings → AI providers."}}
                    _=>{div class="setup-review"{div{span{"Your Space"}strong{(text(&s.setup,"space"))}}div{span{"Profile"}strong{(text(&s.setup,"profile"))}}div{span{"Search"}strong{(match text(&s.setup,"search"){"google"=>"Google","bing"=>"Bing",_=>"DuckDuckGo"})}}div{span{"Privacy"}strong{(if flag(&s.setup,"blockTrackers"){"Blocking on"}else{"Blocking off"})}}div{span{"Modules"}strong{(crate::onboarding::module_choices(s).as_object().map_or(0, |m| m.values().filter(|v| v == &&serde_json::Value::Bool(true)).count()))" on"}}}button class="default-browser" data-op="defaultBrowser"{(icon("globe"))span{"Make Neutrino your default"}(icon("external"))}p class="field-help"{(text(&s.snapshot,"defaultStatus"))}}
                }
            }
            footer class="setup-footer"{(feedback(s))div class="setup-progress" role="progressbar" aria-label="Setup progress" aria-valuemin="1" aria-valuemax=(flow.len()) aria-valuenow=(s.step+1) aria-valuetext=(format!("Step {} of {}: {}",s.step+1,flow.len(),titles[s.step.min(7)])){span class="step-count"{(s.step+1)" of "(flow.len())}@for i in 0..flow.len(){span class=(if i==s.step{"current"}else if i<s.step{"done"}else{""}) aria-hidden="true"{}}}
                div class="setup-actions"{@if s.step>0{button class="button quiet" data-op="setup-back" disabled[s.setup_busy]{(icon("back"))"Back"}}span class="spacer"{}button class="button primary" data-op=(if last{"setup-finish"}else{"setup-next"}) disabled[s.setup_busy]{(if s.setup_busy{"Saving…"}else if last{"Open Neutrino"}else if s.step==0{"Continue"}else if s.step==2&&!flag(&s.snapshot,"imported")||s.step==6&&s.snapshot["preferences"]["ai"].is_null(){"Skip for now"}else{"Continue"})(icon("arrow"))}}
            }
        }
    }}
}
pub(crate) fn segments(op: &str, key: &str, selected: &str, items: &[(&str, &str)]) -> Markup {
    let index = items.iter().position(|(value, _)| *value == selected);
    html! {div class="segments" role="group" style=(format!("--count:{};--index:{}",items.len(),index.unwrap_or(0))) data-selected=(index.is_some().to_string()){@for (value,label) in items{button class=(if *value==selected{"selected"}else{""}) data-op=(op) data-key=[(!key.is_empty()).then_some(key)] data-value=(value) aria-pressed=((*value==selected).to_string()){(label)}}}}
}
pub(crate) fn swatches(s: &Shell, setup: bool) -> Markup {
    let current = if setup {
        text(&s.setup, "accent")
    } else {
        text(&s.config()["theme"], "accent")
    };
    let current = if current == "rose" { "purple" } else { current };
    html! {div class="swatches" role="group" aria-label="Accent color"{@for (value,label) in [("purple","Violet"),("blue","Blue"),("teal","Teal"),("orange","Amber"),("pink","Rose")] {button class=(format!("swatch {} {}",value,if current==value{"selected"}else{""})) data-op=(if setup{"setup-field"}else{"editor-value"}) data-key="accent" data-value=(value) aria-label=(label) aria-pressed=((current==value).to_string()) title=(label){@if current==value{(icon("check"))}}}}}
}
fn editor(s: &Shell) -> Markup {
    html! {div class=(if s.expanded_preview{"editor expanded-preview"}else{"editor"}) {
        header class="editor-header"{div{h1{"Customize"}}div class="editor-actions"{label class="save-scope"{span{"Apply to"}select data-scope="true" aria-label="Where to apply appearance"{option value="true" selected[s.apply_space]{"This Space"}option value="false" selected[!s.apply_space]{"Browser default"}}}(action("Cancel","escape",false))(action("Save changes","editor-save",true))}}
        div class="editor-body"{section class="editor-stage" aria-label="Layout preview"{div class="preview-caption"{span{"Your browser · live layout"}button class="preview-size" data-op="editor-preview-size" aria-expanded=((!s.expanded_preview).to_string()) aria-controls="appearance-controls"{(icon(if s.expanded_preview{"sidebar"}else{"external"}))(if s.expanded_preview{"Show controls"}else{"Expand preview"})}}
            div class="editor-preview"{div class="preview-canvas" inert="" {(browser(s,true))}button type="button" class="edit-selection tabs-selection" draggable="true" data-component="tabs" data-op="editor-select" data-value="tabs" aria-label="Edit tabs"{}button type="button" class="edit-selection nav-selection" draggable="true" data-component="navigation" data-op="editor-select" data-value="navigation" aria-label="Edit navigation"{}button type="button" class="edit-selection panel-selection" draggable="true" data-component="panels" data-op="editor-select" data-value="panels" aria-label="Edit Library panel"{}@for region in ["leading","trailing","top","bottom"]{div class=(format!("dock-target dock-{region}")) data-dock=(region){span{(match region{"leading"=>"Left","trailing"=>"Right","top"=>"Top",_=>"Bottom"})}}}}
            div class="editor-recovery"{button class="icon-button" data-op="editor-undo" title="Undo appearance change" aria-label="Undo appearance change" disabled[s.undo.is_empty()]{(icon("undo"))}button class="icon-button" data-op="editor-redo" title="Redo appearance change" aria-label="Redo appearance change" disabled[s.redo.is_empty()]{(icon("forward"))}button data-op="editor-reset"{"Reset appearance"}span class="editor-feedback" role="status"{(if !text(&s.snapshot,"notice").is_empty(){text(&s.snapshot,"notice")}else if !s.notice.is_empty(){s.notice.as_str()}else{"Changes apply when you save."})}}
        }
        aside class="editor-inspector" id="appearance-controls" hidden[s.expanded_preview]{div class="inspector-section"{h2{"Arrange"}p{"Drag a component, or choose its position."}
            @for (component,label,glyph) in [("tabs","Tabs","sidebar"),("navigation","Navigation","search"),("panels","Library panel","grid")] {div class=(if s.edit_component==component{"component selected"}else{"component"}) draggable="true" data-component=(component){button data-op="editor-select" data-value=(component){(icon(glyph))span{(label)}(icon("grip"))}}}
            div class="position-controls" role="group" aria-label="Component position"{@for (region,label) in [("leading","Left"),("top","Top"),("trailing","Right"),("bottom","Bottom")] { @let valid=s.edit_component=="tabs" || s.edit_component=="navigation"&&["top","bottom"].contains(&region) || s.edit_component=="panels"&&["leading","trailing"].contains(&region);button class=(if text(&s.config()["layout"],match s.edit_component.as_str(){"tabs"=>"tabs","navigation"=>"navigation",_=>"sidebar"})==region{"selected"}else{""}) aria-pressed=((text(&s.config()["layout"],match s.edit_component.as_str(){"tabs"=>"tabs","navigation"=>"navigation",_=>"sidebar"})==region).to_string()) data-op="dock" data-component=(s.edit_component.as_str()) data-region=(region) disabled[!valid]{(label)}}}
            @if s.edit_component=="tabs"{label class="field"{span{"Sidebar width"}input type="range" min="200" max="340" step="4" value=(s.config()["layout"]["tabsWidth"].as_f64().unwrap_or(240.)) data-editor="tabsWidth" aria-label="Sidebar width";}}
        }
        div class="inspector-section"{h2{"Starting layout"}(preset_picker(s,false))}
        div class="inspector-section"{h2{"Browser appearance"}(swatches(s,false))label class="control-label"{"Mode"}(segments("editor-value","colorMode",text(&s.config()["theme"],"colorMode"),&[("system","System"),("light","Light"),("dark","Dark")]))button class="toggle-row" data-op="editor-value" data-key="reducedMotion" data-value=((!flag(&s.config()["theme"],"reducedMotion")).to_string()) data-type="bool" role="switch" aria-checked=(flag(&s.config()["theme"],"reducedMotion").to_string()){span{strong{"Reduce motion"}}span class=(if flag(&s.config()["theme"],"reducedMotion"){"switch on"}else{"switch"}){span{}}}label class="control-label"{"Density"}(segments("editor-value","density",text(&s.config()["theme"],"density"),&[("comfortable","Roomy"),("compact","Compact")]))}
        (appearance_controls(s))(editor_extra(s))div class="inspector-section"{h2{"Saved setups"}@for c in array(&s.snapshot["savedConfigurations"]){div class="saved-setup-row"{input value=(text(c,"name")) data-setup-name=(text(c,"id")) maxlength="80" aria-label=(format!("Rename {}",text(c,"name")));button class="icon-button" data-op="editor-replace-named" data-id=(text(c,"id")) title="Replace with current draft" aria-label=(format!("Replace {} with current draft",text(c,"name"))){(icon("check"))}button class="icon-button" data-op="editor-delete-named" data-id=(text(c,"id")) aria-label=(format!("Delete {}",text(c,"name"))){(icon("close"))}button class="saved-setup" data-op="editor-load-named" data-id=(text(c,"id")){(icon("sidebar"))"Use setup"}}}label class="field"{span{"Name this setup"}input data-name="true" value=(s.name.as_str()) maxlength="80" placeholder="Research, Work, Personal…";}button class="button" data-op="editor-save-named" disabled[s.name.is_empty()]{"Save setup"}}
        }
        }
    }}
}
pub(crate) fn preset_picker(s: &Shell, setup: bool) -> Markup {
    let selected = if setup {
        text(&s.setup, "preset")
    } else {
        text(&s.config()["theme"], "preset")
    };
    html! {div class="preset-grid" role="group" aria-label="Browser starting layout"{
        @for (id,label,detail) in crate::appearance::PRESETS {
            button class=(if selected==*id{"preset-card selected"}else{"preset-card"}) data-op=(if setup{"setup-preset"}else{"editor-preset"}) data-value=(id) aria-pressed=((selected==*id).to_string()) title=(detail){
                span class="preset-thumbnail" data-browser=(id){i class="preset-tabs"{}i class="preset-address"{}i class="preset-page"{}i class="preset-panel"{}}
                span class="preset-label"{strong{(label)}@if selected==*id{(icon("check"))}}
            }
        }
    }}
}
fn slider(
    s: &Shell,
    label: &str,
    key: &str,
    target: &str,
    min: f64,
    max: f64,
    step: f64,
    default: f64,
) -> Markup {
    let value = s.config()[target][key].as_f64().unwrap_or(default);
    html! {label class="editor-slider"{span{(label)output{(format!("{value:.2}").trim_end_matches('0').trim_end_matches('.'))}}input type="range" min=(min) max=(max) step=(step) value=(value) data-editor=(key) aria-label=(label);}}
}
fn editor_extra(s: &Shell) -> Markup {
    let layout = &s.config()["layout"];
    let items: Vec<&str> = array(&layout["toolbarItems"]).iter().filter_map(Value::as_str).collect();
    let accent = text(&s.config()["theme"], "accentHex");
    html! {
        div class="inspector-section"{h2{"Color"}
            label class="field color-field"{span{"Any accent color"}input type="color" data-editor-color="accentHex" value=(if crate::appearance::hex(accent) {format!("#{}", accent.trim_start_matches('#'))} else {"#7c5cff".to_string()}) aria-label="Accent color";}
            div class="theme-chips" role="group" aria-label="Themes"{@for (name, hex) in crate::appearance::GX_THEMES.iter().copied().chain(crate::appearance::VIVALDI_THEMES.iter().filter(|t| t.0 != "system" && t.0 != "dark").map(|t| (t.1, t.3))) {button class="theme-chip" data-op="editor-value" data-key="accentHex" data-value=(hex) title=(name) aria-label=(format!("{name} theme")) style=(format!("--chip:#{hex}")){}}}
        }
        div class="inspector-section"{h2{"Toolbar"}
            p{"Choose extra buttons for the toolbar."}
            div class="toolbar-choices"{@for (key, label, glyph) in TOOLBAR_ITEMS {
                @let on = items.contains(key);
                @let next: Vec<&str> = if on { items.iter().copied().filter(|i| i != key).collect() } else { items.iter().copied().chain([*key]).collect() };
                button class=(if on {"toolbar-choice selected"} else {"toolbar-choice"}) data-op="editor-value" data-key="toolbarItems" data-json=(serde_json::to_string(&next).unwrap_or_default()) aria-pressed=(on.to_string()){(icon(glyph))span{(label)}}
            }}
            @for (key, label) in [("panelBar","Panel bar"),("statusBar","Status bar"),("compactRail","Icon-only sidebar")] {button class="toggle-row" data-op="editor-value" data-key=(key) data-value=((!flag(layout,key)).to_string()) data-type="bool" role="switch" aria-checked=(flag(layout,key).to_string()){span{(label)}span class=(if flag(layout,key){"switch on"}else{"switch"}){span{}}}}
            label class="control-label"{"Split view"}(segments("editor-value","split",if text(layout,"split").is_empty(){"sideBySide"}else{text(layout,"split")},&[("sideBySide","Side by side"),("stacked","Stacked")]))
        }
    }
}
fn appearance_controls(s: &Shell) -> Markup {
    html! {
        div class="inspector-section"{h2{"Shape & type"}
            (slider(s,"Corners","cornerRadius","theme",0.,24.,1.,8.))
            (slider(s,"Text size","fontScale","theme",0.85,1.4,0.05,1.))
            (slider(s,"Spacing","spacingScale","theme",0.75,1.5,0.05,1.))
            (segments("editor-value","typography",text(&s.config()["theme"],"typography"),&[("system","System"),("rounded","Rounded"),("monospaced","Mono")]))
        }
        div class="inspector-section"{h2{"SVG icons"}
            div class="icon-pack-grid"{@for (key,label) in [("outline","Outline"),("precision","Precision"),("solid","Solid"),("module","Module")] {button class=(if text(&s.config()["theme"],"iconPack")==key{"icon-pack selected"}else{"icon-pack"}) data-op="editor-value" data-key="iconPack" data-value=(key) aria-pressed=((text(&s.config()["theme"],"iconPack")==key).to_string()){span{svg class="icon" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.7" fill=(if key=="solid"{"currentColor"}else{"none"}){path d=(crate::icons::path("folder",key)){}}svg class="icon" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.7" fill="none"{path d=(crate::icons::path("search",key)){}}}(label)}}}
            (slider(s,"Stroke","iconStroke","theme",1.,2.5,0.1,1.7))
        }
        div class="inspector-section"{h2{"Page tools"}
            (segments("editor-value","secondaryPanel",text(&s.config()["layout"],"secondaryPanel"),&[("","None"),("notes","Notes"),("bookmarks","Bookmarks"),("resources","Monitor")]))
            (slider(s,"Panel width","sidebarWidth","layout",180.,360.,10.,300.))
            button class="toggle-row" data-op="editor-value" data-key="bookmarksBar" data-value=((!flag(&s.config()["layout"],"bookmarksBar")).to_string()) data-type="bool" role="switch" aria-checked=(flag(&s.config()["layout"],"bookmarksBar").to_string()){span{"Bookmarks bar"}span class=(if flag(&s.config()["layout"],"bookmarksBar"){"switch on"}else{"switch"}){span{}}}
        }
    }
}

fn palette(s: &Shell) -> Markup {
    let results = s.results();
    html! {div class="palette-scrim" data-dismiss="true"{div class="palette-frame"{section class="command-palette" role="dialog" aria-modal="true" aria-label="Search and switch tabs"{div class="palette-grip" data-drag-dialog="true" tabindex="0" role="button" aria-label="Move command palette with arrow keys"{(icon("grip"))span{(if s.palette_new{"Open a new tab"}else{"Quick navigation"})}span class="spacer"{}kbd{(if s.palette_new{"⌘T"}else{"⌘K"})}}div class="command-field"{(icon("search"))input id="command-input" type="text" autocomplete="off" spellcheck="false" placeholder="Search or enter a URL" value=(s.query.as_str()) aria-label="Search, enter a URL, or find a tab" role="combobox" aria-expanded="true" aria-controls="command-results" aria-activedescendant=(format!("result-{}",s.selected_result));button class="icon-button" data-op="escape" aria-label="Close command bar"{(icon("close"))}}
        div class="command-results" id="command-results" role="listbox"{@for (index,r) in results.iter().enumerate(){button id=(format!("result-{index}")) class=(if index==s.selected_result{"command-result selected"}else{"command-result"}) data-op="select-result" data-index=(index) role="option" aria-selected=((index==s.selected_result).to_string()){@match text(r,"kind"){"tab"=>{(site(r))},"action"=>{span class="result-glyph"{(icon(crate::features::ACTIONS.iter().find(|a|a.0==text(r,"value")).map(|a|a.2).unwrap_or("code")))}},"search" if !text(r,"url").is_empty()=>{(site(r))},"command"=>{span class="result-glyph"{(icon(match text(r,"value"){"modules"=>"grid","settings"=>"settings","extensions"=>"plug","editor"=>"appearance","library"=>"bookmark",_=>"undo"}))}},_=>{span class="result-glyph"{(icon("search"))}}}span class="result-text"{strong{(text(r,"title"))}small{(if text(r,"kind")=="tab" || !text(r,"url").is_empty(){readable(text(r,"detail"))}else{text(r,"detail").into()})}}span class="result-kind"{(match text(r,"kind"){"tab"=>"Switch to tab","command"=>"Go to","action"=>"Run",_=>"Open"})kbd{"↵"}}}}
        @if results.is_empty(){div class="command-empty"{"Type to search the web, open an address, find a tab, or run an action like “split” or “print”."}}}
        footer class="command-footer"{span{kbd{"↑"}kbd{"↓"}" to move"}span{kbd{"↵"}" to open"}}
    }}}}
}
fn utility(s: &Shell) -> Markup {
    match s.screen.as_str() {
        "resources" => resources(s),
        "settings" => settings(s),
        "library" => library(s),
        "assistant" => assistant(s),
        "reader" => {
            let r = &s.snapshot["preferences"]["readerStyle"];
            html! {article class="reader-content" data-theme=(r["theme"].as_str().unwrap_or("auto")) data-font=(r["font"].as_str().unwrap_or("serif")) style=(crate::views::reader_style(s)) {
                @for (i, block) in text(&s.snapshot,"assistantResponse").split("\n\n").filter(|b| !b.trim().is_empty()).enumerate().take(4000) {
                    @if i == 0 {h1{(block.trim())}} @else if block.trim().len() < 90 && !block.trim().ends_with('.') {h2{(block.trim())}} @else {p{(block.trim())}}
                }
            }}
        }
        "source" => crate::views::source(s),
        "extensions" => extensions(s),
        "modules" => modules(s),
        "recovery" => {
            html! {div class="settings-content"{h2{"Recovery"}p class="section-description"{"Fix a broken layout or module. Your tabs, bookmarks and passwords are kept."}
                div class="list-row"{div{strong{"Restore appearance"}small{"Reset the browser default and this Space’s layout."}}(action("Restore layout","restoreLayout",false))}
                div class="list-row"{div{strong{"Reset optional modules"}small{"Keep a local backup and stop optional features."}}button class="button" data-op="menu" data-value="reset-modules"{"Reset modules…"}}
                div class="list-row"{div{strong{"Save your data"}small{"Retry a failed save."}}(action("Retry save","retrySave",false))}
                div class="list-row"{div{strong{"Local backups"}small{"Inspect Neutrino’s data folder."}}(action("Show in Finder","showDataFolder",false))}div class="list-row"{div{strong{"Uninstall Neutrino"}small{"Permanently erase the app and its browser data. Downloads are kept."}}button class="button danger" data-op="uninstall"{"Uninstall…"}}
            }}
        }
        _ => html! {},
    }
}
fn resources(s: &Shell) -> Markup {
    let r = &s.snapshot["resources"];
    html! {div class="resources-content"{
        @if !text(r,"failure").is_empty(){div class="resource-error" role="status"{p{(text(r,"failure"))}button class="button" data-op="native" data-action="retryResources"{"Try again"}button class="button quiet" data-op="screen" data-value="modules"{"Choose provider"}}}
        @else if r["frame"].is_object(){h2{(text(&r["frame"],"title"))}div class="resource-grid"{@for metric in array(&r["frame"]["metrics"]){article class="resource-metric"{h3{(text(metric,"name"))}strong{(text(metric,"value"))}@if array(&metric["samples"]).len()>1{svg class="resource-sparkline" viewBox="0 0 240 60" preserveAspectRatio="none" aria-label=(format!("Recent {} samples",text(metric,"name"))){polyline fill="none" stroke="currentColor" stroke-width="2" points=(array(&metric["samples"]).iter().enumerate().map(|(i,v)|format!("{},{}",i as f64*240./(array(&metric["samples"]).len()-1)as f64,58.-v.as_f64().unwrap_or(0.).clamp(0.,1.)*56.)).collect::<Vec<_>>().join(" "));}}@if let Some(f)=metric["fraction"].as_f64(){progress max="1" value=(f.clamp(0.,1.)) aria-label=(text(metric,"name")) {}}@if !text(metric,"detail").is_empty(){p{(text(metric,"detail"))}}}}}p class="field-help"{(text(&r["frame"],"detail"))}}
        @else {div class="resource-loading" role="status"{span class="loading-spinner"{}"Starting resource provider…"}}
    }}
}
fn settings(s: &Shell) -> Markup {
    let prefs = &s.snapshot["preferences"];
    let sections = [("general","General","settings"),("profiles","Profiles","user"),("privacy","Privacy","shield"),("search","Search","search"),("passwords","Passwords","key"),("autofill","Autofill","user"),("appearance","Appearance","edit"),("performance","Performance","activity"),("shortcuts","Shortcuts","code"),("ai","AI providers","spark"),("updates","Updates & engines","download")];
    html! {div class="settings-layout"{nav class="settings-nav" aria-label="Settings sections"{@for (key,label,glyph) in sections {button class=(if s.section==key || key=="general" && !sections.iter().any(|x|x.0==s.section) && s.section!="engines" {"selected"}else{""}) data-op="section" data-value=(key) aria-current=[(s.section==key).then_some("page")]{(icon(glyph))(label)}}}
        div class="settings-content"{@if let Some(section) = crate::views::settings_section(s) {(section)} @else {@match s.section.as_str(){
            "profiles"=>{h2{"Your Profiles"}p class="section-description"{"Separate website accounts, cookies and extensions. Spaces can share a Profile."}@for p in array(&s.snapshot["profiles"]){div class="list-row"{(icon("user"))div{strong{(text(p,"name"))}small{(if p["id"]==s.snapshot["session"]["profileID"]{"Current Profile"}else{"Separate browsing data"})}}div class="button-row"{button class="button" data-op="native" data-action="switchProfile" data-id=(text(p,"id")) disabled[s.private() || p["id"]==s.snapshot["session"]["profileID"]]{"Switch"}@if array(&s.snapshot["profiles"]).len()>1 && p["id"]!=s.snapshot["session"]["profileID"] {button class="icon-button" data-op="menu" data-value=(format!("delete-profile:{}",text(p,"id"))) aria-label=(format!("Delete {}",text(p,"name"))) disabled[s.private()]{(icon("trash"))}}}}}button class="button" data-op="menu" data-value="new-profile"{"Add Profile"}}
            "privacy"=>{h2{"Privacy"}(toggle("Block trackers","Stops analytics and cross-site tracking. Applies to every Profile.","blockTrackers",prefs["blockTrackers"].as_bool().unwrap_or(true),false))
                @if prefs["blockTrackers"].as_bool().unwrap_or(true){(toggle("Block ads too","Removes most advertising.","blockAds",prefs["blockAds"].as_bool().unwrap_or(true),false))}
                @if !array(&prefs["shieldsDown"]).is_empty(){div class="settings-group"{h3{"Sites with blocking turned off"}@for site in array(&prefs["shieldsDown"]).iter().filter_map(Value::as_str){div class="list-row"{(icon("globe"))div{strong{(site)}small{"Nothing is blocked on this site."}}button class="button" data-op="shields-restore" data-value=(site){"Turn blocking back on"}}}}}(toggle("Block popups","Popups you open with a click still appear.","blockPopups",flag(prefs,"blockPopups"),false))(crate::views::privacy_extra(s))p class="field-help"{"Private windows do not save tabs or history. Downloads remain on disk. Private browsing does not hide activity from websites or your network."}}
            "appearance"=>{h2{"Appearance"}p class="section-description"{"Arrange tabs and panels, choose colors, and set up each Space."}button class="appearance-preview" data-op="screen" data-value="editor"{(icon("edit"))span{"Open the appearance editor"}(icon("arrow"))}(crate::views::appearance_extra(s))}
            "ai"=>{h2{"AI providers"}p class="section-description"{"Bring a key or use a local endpoint. Secrets are saved in macOS Keychain."}(ai_form(s))}
            "passwords"=>{h2{"Passwords"}p class="section-description"{"Saved locally in macOS Keychain, separate for each Profile."}
                @for c in array(&s.snapshot["credentials"]) {div class="list-row"{(icon("key"))div{strong{(text(c,"origin"))}small{(text(c,"username"))}}div class="button-row"{button class="button" data-op="native" data-action="credentialFill" data-id=(text(c,"id")){"Fill on this page"}button class="icon-button" data-op="menu" data-value=(format!("delete-credential:{}",text(c,"id"))) aria-label="Delete saved login"{(icon("close"))}}}}
                @if !s.private(){details class="credential-disclosure"{summary{"Add a login"}form data-form="credential"{
                    label class="field"{span{"Website"}input name="origin" type="url" placeholder="https://example.com" required="";}
                    label class="field"{span{"Username"}input name="username" autocomplete="off" maxlength="500";}
                    label class="field"{span{"Password"}span class="password-field"{input name="password" type="password" autocomplete="new-password" required="";button class="button quiet" type="button" data-generate="password"{"Generate"}}}
                    button class="button primary" type="submit"{"Save login"}
                }}
                div class="button-row"{button class="button" data-op="native" data-action="importPasswords"{"Import CSV…"}button class="button" data-op="native" data-action="exportPasswords" disabled[array(&s.snapshot["credentials"]).is_empty()]{"Export CSV…"}}
                @if !s.private() {details class="credential-disclosure"{summary{"Import from another browser"}
                    p class="field-help"{"Reads the browser’s saved passwords on this Mac. macOS asks before Neutrino can use that browser’s password key."}
                    div class="button-row"{@for id in crate::onboarding::PASSWORD_SOURCES {button class="button" data-op="browser-passwords" data-value=(id){(crate::onboarding::IMPORT_SOURCES.iter().find(|(i, _)| i == id).map(|(_, n)| *n).unwrap_or(id))}}}
                }}}
            }
            "updates"|"engines"=>{h2{"Updates"}p class="section-description"{(text(&s.snapshot["updates"],"version"))}(toggle("Automatic updates","Update Neutrino and Chromium together after you quit. Your data stays in place.","automaticUpdates",flag(&s.snapshot["updates"],"automatic"),false))div class="settings-group"{
                p{(text(&s.snapshot["updates"],"message"))}
                div class="button-row"{
                    button class="button" data-op="checkUpdates" disabled[flag(&s.snapshot["updates"],"busy")]{(if flag(&s.snapshot["updates"],"busy"){"Checking…"}else{"Check for updates"})}
                    @if !text(&s.snapshot["updates"],"available").is_empty() && !flag(&s.snapshot["updates"],"pending"){button class="button primary" data-op="downloadUpdate" disabled[flag(&s.snapshot["updates"],"busy")]{"Download "(text(&s.snapshot["updates"],"available"))}}
                    @if flag(&s.snapshot["updates"],"pending"){(action("Restart and install","restartUpdate",false))}
                    @if flag(&s.snapshot["updates"],"busy"){(action("Cancel","cancelUpdate",false))}
                    @if flag(&s.snapshot["updates"],"pending") || flag(&s.snapshot["updates"],"invalid"){button class="button" data-op="discardUpdate" disabled[flag(&s.snapshot["updates"],"busy")]{"Discard download"}}
                }
                button class="button" data-op="importInstaller" disabled[flag(&s.snapshot["updates"],"busy")]{(icon("folder"))"Import offline installer…"}
            }
            h2{"Website engines"}p class="section-description"{"Blink is the default. WebKit uses separate website sign-ins and does not support Chrome extensions."}
            div class="list-row"{(icon("globe"))div{strong{"Blink / Chromium"}small{(if flag(&s.snapshot,"blinkAvailable"){format!("Chromium {} · updates with Neutrino",text(&s.snapshot,"engineVersion"))}else{"Not present in this development build".into()})}}}
            div class="list-row"{(icon("globe"))div{strong{"WebKit"}small{"Provided by macOS"}}}}

            _=>{h2{"Browsing"}(crate::views::general_extra(s))label class="control-label"{"Default search engine"}(segments("preference","search",text(prefs,"search"),&[("duckDuckGo","DuckDuckGo"),("google","Google"),("bing","Bing")]))@if !text(prefs,"defaultSearchID").is_empty(){p class="field-help"{"A custom engine is your default. Change it in Settings → Search."}}div class="list-row"{div{strong{"Default browser"}small{"Open links in Neutrino."}}(action("Set as default","defaultBrowser",false))}div class="list-row"{div{strong{"Import bookmarks"}small{"Choose an HTML export from another browser."}}(action("Import…","importBookmarks",false))}div class="list-row"{div{strong{"Uninstall Neutrino"}small{"Erase this app and its browser data."}}button class="button danger" data-op="uninstall"{"Uninstall…"}}}
        }}}
    }}
}
pub(crate) fn empty(title: &str, detail: &str, glyph: &str) -> Markup {
    html! {div class="empty-state"{(icon(glyph))h3{(title)}p{(detail)}}}
}
fn library(s: &Shell) -> Markup {
    let section = if ["bookmarks", "history", "downloads", "notes", "archive", "reading", "sessions", "boards"]
        .contains(&s.section.as_str())
    {
        s.section.as_str()
    } else {
        "bookmarks"
    };
    let page = s.snapshot["libraryPage"].as_u64().unwrap_or(0);
    let count = s.snapshot["libraryCount"].as_u64().unwrap_or(0);
    html! {div class="library-content" {
        @if !flag(&s.snapshot,"downloadsWindow") {nav class="library-tabs" aria-label="Library sections" {
            @for (key,label,glyph) in [("bookmarks","Bookmarks","bookmark"),("reading","Reading List","book"),("history","History","history"),("downloads","Downloads","download"),("notes","Notes","edit"),("boards","Boards","grid"),("sessions","Sessions","folder"),("archive","Archived","undo")].into_iter().filter(|(k,_,_)| crate::features::on(s, match *k {"reading" => "reading-list", "boards" => "boards", "sessions" => "sessions", _ => "*"})) {
                button class=(if section==key{"selected"}else{""}) data-op="section" data-value=(key) title=(label) aria-label=(label) aria-pressed=((section==key).to_string()){(icon(glyph))span{(label)}}
            }
        }
        }
        @match section {
            "history" => {(crate::views::history(s))}
            "downloads" => {(crate::views::downloads(s))}
            "reading" => {(crate::views::reading(s))}
            "sessions" => {(crate::views::sessions(s))}
            "boards" => {(crate::views::boards(s))}
            "archive" => {
                @if array(&s.snapshot["archived"]).is_empty(){(empty("No archived tabs","Tabs you close in this Space can be restored from here.","folder"))}
                @for t in array(&s.snapshot["archived"]) {div class="list-row"{(site(t))div{strong{(text(t,"title"))}small{(host(text(t,"url")))}}button class="button" data-op="native" data-action="restoreArchived" data-id=(text(t,"id")){"Restore"}}}
            }
            "notes" => {
                @if s.private() {(empty("Notes stay in regular windows","Private browsing does not create or change saved notes.","shield"))}
                @else {
                    div class="notes-toolbar"{div class="notes-scope"{button id="notes-scope-trigger" class="selected" data-op="menu" data-value="notes-scope" aria-haspopup="dialog" title="Choose which notes to show"{(if text(&s.snapshot,"notesScope")=="all"{"All notes"}else{"This Space"})(icon("down"))}}div class="note-actions"{button class="icon-button" data-op="native" data-action="createNote" aria-label="New note" title="New note"{(icon("plus"))}button class="icon-button" data-op="native" data-action="noteFromPage" aria-label="Save page as a note" title="Save page as a note" disabled[text(s.active(),"url").is_empty()]{(icon("bookmark"))}button class="icon-button" data-op="native" data-action="quoteSelection" aria-label="Quote selected text" title="Quote selected text" disabled[text(s.active(),"url").is_empty()]{(icon("quote"))}}}
                    input class="notes-search" type="search" data-notes-query="true" placeholder="Search notes and quotations" value=(text(&s.snapshot,"notesQuery")) maxlength="160" aria-label="Search note text, quotations, titles, sources and Spaces";
                    div class="note-list" {@for n in array(&s.snapshot["notes"]) {button class=(if n["id"]==s.snapshot["selectedNote"]["id"]{"selected"}else{""}) data-op="native" data-action="selectNote" data-id=(text(n,"id")){span{strong{(text(n,"title"))}@if !text(n,"excerpt").is_empty(){span class="note-excerpt"{(text(n,"excerpt").split_whitespace().collect::<Vec<_>>().join(" "))}}@if !text(n,"sourceURL").is_empty(){small{(host(text(n,"sourceURL")))}}@if text(&s.snapshot,"notesScope")=="all" && !text(n,"spaceName").is_empty(){small{(text(n,"spaceName"))}}}}}}
                    @if array(&s.snapshot["notes"]).is_empty(){div class="notes-empty"{@if !text(&s.snapshot,"notesQuery").is_empty(){p{"No notes match this search."}button class="button quiet" data-op="native" data-action="notesQuery" data-value=""{"Clear search"}}@else{p{(if text(&s.snapshot,"notesScope")=="all"{"No saved notes yet."}else{"No notes in this Space yet."})}}}}
                    @let n=&s.snapshot["selectedNote"];
                    @if !n.is_null() {article class="note-card"{
                        div class="note-heading"{input class="note-title" value=(text(n,"title")) data-note=(text(n,"id")) data-note-field="title" maxlength="100" aria-label="Note title";button class="icon-button" data-op="menu" data-value=(format!("delete-note:{}",text(n,"id"))) aria-label="Note actions"{(icon("more"))}}
                        @if !text(n,"sourceURL").is_empty(){button class="note-source" data-op="native" data-action="openNoteSource" data-id=(text(n,"id")) title=(format!("Open {} in {} · {}",text(n,"sourceTitle"),text(n,"spaceName"),text(n,"sourceURL"))){(icon("external"))span{(host(text(n,"sourceURL")))" · "(text(n,"spaceName"))}"Open source"}}
                        @if !text(n,"quotedText").is_empty(){details class=(format!("note-quotation quote-{}",text(n,"id"))){summary{span{"Quotation"}span class="note-excerpt"{(text(n,"excerpt").split_whitespace().collect::<Vec<_>>().join(" "))}}blockquote class="note-quote"{(text(n,"quotedText"))}}}
                        textarea data-note=(text(n,"id")) data-note-field="body" maxlength="200000" aria-label="Note content" placeholder="Add your notes…"{(text(n,"text"))}
                    }}
                }
            }
            _ => {(crate::views::bookmarks(s))}
        }
        @if count>40 && ["bookmarks","history","notes"].contains(&s.section.as_str()) {
            div class="library-pagination"{button class="button" data-op="native" data-action="libraryPage" data-value=(page.saturating_sub(1)) disabled[page==0]{"Previous"}span{(page*40+1)"–"((page*40+40).min(count))" of "(count)}button class="button" data-op="native" data-action="libraryPage" data-value=(page+1) disabled[(page+1)*40>=count]{"Next"}}
        }
    }}
}

fn ai_form(s: &Shell) -> Markup {
    let config = &s.snapshot["preferences"]["ai"];
    let account = &s.snapshot["account"];
    html! {form class="ai-form" data-form="ai"{
        label class="field"{span{"Provider"}select name="provider"{@for (id,label) in [("openAI","OpenAI"),("xAI","xAI"),("local","Local model")] {option value=(id) selected[text(config,"provider")==id]{(label)}}}}
        label class="field"{span{"Connection"}select name="useAccount"{option value="key" selected[!flag(config,"useAccount")]{"API key or local endpoint"}option value="account" selected[flag(config,"useAccount")] disabled[!flag(account,"connected")]{"Connected OpenAI account"}}}
        label class="field"{span{"Endpoint"}input name="endpoint" type="url" value=(if text(config,"endpoint").is_empty(){"https://api.openai.com/v1"}else{text(config,"endpoint")}) required;}
        label class="field"{span{"Model"}input name="model" list="account-models" value=(text(config,"model")) placeholder="Model identifier" required;}
        datalist id="account-models"{@for name in array(&account["models"]){option value=(name.as_str().unwrap_or(""));}}
        label class="field"{span{"API key"}input name="key" type="password" autocomplete="new-password" placeholder="Stored in macOS Keychain";}
        div class="button-row"{button class="button primary" type="submit"{"Save provider"}
            @if flag(account,"busy"){button class="button" type="button" data-op="cancelAI"{"Cancel sign-in"}}
            @else if flag(account,"connected"){button class="button" type="button" data-op="disconnectAI"{"Disconnect account"}}
            @else {button class="button" type="button" data-op="signIn"{"Connect OpenAI account"}}
        }
        p class="field-help" role="status"{(text(account,"status"))}
        @if !config.is_null(){button class="button quiet" type="button" data-op="disableAI"{"Turn AI off"}}
        p class="field-help"{"xAI account sign-in is not available yet. You can use an xAI API key."}
    }}
}

fn assistant(s: &Shell) -> Markup {
    html! {div class="assistant-content"{@if s.snapshot["preferences"]["ai"].is_null(){(empty("Connect an AI provider","Ask questions about the page you’re reading. You need an API key, an OpenAI account, or a local model.","spark"))button class="button primary" data-op="screen" data-value="settings" data-section="ai"{"Set up a provider"}} @else {p class="section-description"{"Ask about this page. Sending shares the page’s text with your configured provider."}div class="assistant-response"{(text(&s.snapshot,"assistantResponse"))}form data-form="assistant"{label class="field"{span{"Your question"}textarea name="prompt" placeholder="What would you like to know?" required{}}button class="button primary" type="submit" disabled[flag(&s.snapshot,"assistantBusy")]{(if flag(&s.snapshot,"assistantBusy"){"Thinking…"}else{"Share page and ask"})}}}}}
}
fn module_glyph(id: &str) -> &str {
    let feature = match id.strip_prefix("org.neutrino.").unwrap_or("") {
        "tab-sleep" => "moon",
        "tab-islands" | "tab-stacks" => "folder",
        "favorites" => "star",
        "tidy-tabs" => "spark",
        "peek" | "little-arc" => "external",
        "link-routes" => "forward",
        "mouse-gestures" | "command-chains" => "code",
        "page-styles" | "boosts" | "interface-css" | "wallpapers" | "theme-schedule" => "appearance",
        "cookie-banners" | "forget-sites" | "panic" => "shield",
        "autofill" => "user",
        "web-panels" => "panel",
        "boards" | "speed-dial" => "grid",
        "reading-list" => "book",
        "sessions" => "folder",
        "media-controls" | "sounds" => "volume",
        "break-mode" => "pause",
        "limiter" => "activity",
        _ => "",
    };
    if !feature.is_empty() {
        feature
    } else if id.contains("theme") {
        "spark"
    } else if id.contains("tabs") || id.contains("layout") {
        "sidebar"
    } else if id.contains("notes") {
        "edit"
    } else if id.contains("reader") {
        "book"
    } else if id.contains("monitor") {
        "activity"
    } else if id.contains("screenshot") {
        "camera"
    } else if id.contains("focus") {
        "focus"
    } else {
        "grid"
    }
}
/// Modules grouped as in setup: built-in features by area, then everything else.
fn module_groups<'a>(shown: &[&'a Value]) -> Vec<(&'static str, Vec<&'a Value>)> {
    let mut groups: Vec<(&'static str, Vec<&'a Value>)> = vec![];
    for m in shown {
        let group = crate::features::MODULES.iter().find(|f| text(m, "capability") == "feature" && text(m, "id") == format!("org.neutrino.{}", f.0)).map_or("Tools and looks", |f| f.1);
        match groups.iter_mut().find(|g| g.0 == group) {
            Some(g) => g.1.push(m),
            None => groups.push((group, vec![m])),
        }
    }
    groups.sort_by_key(|g| if g.0 == "Tools and looks" { 0 } else { 1 + crate::features::MODULES.iter().position(|f| f.1 == g.0).unwrap_or(99) });
    groups
}
fn module_description(module: &Value) -> &str {
    match text(module, "id") {
        "org.neutrino.notes" => "Write notes and save quotes beside the page you’re reading.",
        "org.neutrino.reader" => "Show the current article as plain, readable text.",
        "org.neutrino.focus" => "Hide the sidebar and toolbar. Press Esc to bring them back.",
        "org.neutrino.resource-monitor" => "See CPU and memory use while you browse.",
        "org.neutrino.memory-monitor" => "See how your Mac’s memory is being used, in detail.",
        _ => text(module, "description"),
    }
}
fn modules(s: &Shell) -> Markup {
    let all = array(&s.snapshot["modules"]);
    if let Some(m) = all.iter().find(|m| text(m, "id") == s.selected_module) {
        return module_details(s, m);
    }
    let query = s.module_query.to_lowercase();
    let shown: Vec<_> = all
        .iter()
        .filter(|m| {
            (s.module_filter == "all"
                || s.module_filter == "installed" && flag(m, "installed")
                || s.module_filter == "available" && !flag(m, "installed"))
                && (query.is_empty()
                    || text(m, "name").to_lowercase().contains(&query)
                    || module_description(m).to_lowercase().contains(&query))
        })
        .collect();
    html! {div class="modules-content"{
        div class="modules-toolbar"{(segments("module-filter","",s.module_filter.as_str(),&[("installed","Installed"),("available","Available"),("all","All")]))label class="module-search"{(icon("search"))input id="module-search" data-module-search="true" type="search" value=(s.module_query.as_str()) placeholder="Search modules" aria-label="Search modules" autocomplete="off";}span class="spacer"{}button class="button" data-op="importModule" title="Install a module package from a file"{(icon("plus"))"Add from file…"}}
        @if all.is_empty(){(empty("Modules could not load","Open Recovery to repair module storage, or import a local package.","grid"))(action("Open Recovery","module-recovery",false))}
        @else if shown.is_empty(){(empty("No matching modules","Try another search or view the available modules.","search"))}
        @else {@for (group, members) in module_groups(&shown) {
            @if module_groups(&shown).len() > 1 {h2 class="module-group-title"{(group)}}
            div class="module-grid"{@for m in members{article class="module-card"{
            button class="module-open" data-op="module-select" data-value=(text(m,"id")) aria-label=(format!("{} details",text(m,"name"))){span class="module-icon"{(icon(module_glyph(text(m,"id"))))}div{h2{(text(m,"name"))}p{(module_description(m))}}}
            div class="module-card-footer"{span class=(if flag(m,"enabled"){"module-status active"}else{"module-status"}){(if flag(m,"enabled"){"Active"}else if flag(m,"installed"){"Disabled"}else{"Available"})}span class="spacer"{}button class="button quiet" data-op="native" data-action=(if flag(m,"installed"){"toggleModule"}else{"installModule"}) data-id=(text(m,"id")){(if !flag(m,"installed"){"Install"}else if flag(m,"enabled"){"Disable"}else if flag(m,"replacesProvider"){"Replace provider"}else{"Enable"})}}
        }}}
        }}
        footer class="modules-footer"{span{(all.iter().filter(|m|flag(m,"enabled")).count())" of "(all.len())" modules on"}button class="button quiet" data-op="native" data-action="importCatalog" title="Add a list of modules published by someone else"{"Add a catalog…"}}
    }}
}
fn module_details(s: &Shell, m: &Value) -> Markup {
    let id = text(m, "id");
    html! {div class="module-details"{
        button class="button quiet" data-op="module-select" data-value=""{(icon("back"))"All modules"}
        @if !text(m,"error").is_empty(){p class="field-error" role="alert"{(text(m,"error"))}}
        header class="module-detail-heading"{span class="module-icon"{(icon(module_glyph(id)))}div{h2{(text(m,"name"))}p{(module_description(m))}}}
        div class="module-detail-actions"{button class=(if flag(m,"enabled"){"button"}else{"button primary"}) data-op="native" data-action=(if flag(m,"installed"){"toggleModule"}else{"installModule"}) data-id=(id){(if !flag(m,"installed"){"Install"}else if flag(m,"enabled"){"Disable"}else if flag(m,"replacesProvider"){"Replace provider"}else{"Enable"})}
            @if flag(m,"updateAvailable"){button class="button" data-op="native" data-action="installModule" data-id=(id){"Update to v"(m["availableVersion"].as_u64().unwrap_or(1))}}
            @if flag(m,"installed") && flag(m,"available"){button class="button" data-op="native" data-action="repairModule" data-id=(id){"Reinstall"}}
            @if flag(m,"installed"){button class="button danger" data-op="native" data-action="uninstallModule" data-id=(id){"Remove…"}}
        }
        @if flag(m,"enabled"){div class="module-use"{@match text(m,"capability"){
            "resourceMonitor"=>{button class="button primary" data-op="screen" data-value="resources"{(icon("activity"))"Open monitor"}}
            "focusMode"=>{button class="button primary" data-op="native" data-action="toggleFocus"{(icon("focus"))(if flag(&s.snapshot,"focusMode"){"Exit Focus"}else{"Enter Focus"})}}
            "notes"=>{button class="button primary" data-op="open-panel" data-value="notes"{(icon("edit"))"Open beside page"}}
            "reader"=>{button class="button primary" data-op="reader" disabled[text(s.active(),"url").is_empty()]{(icon("book"))"Read current page"}}
            "screenshot"=>{button class="button primary" data-op="capture" disabled[text(s.active(),"url").is_empty()]{(icon("camera"))"Capture current page"}}
            "theme" | "layout" | "icons" | "tabSystem"=>{button class="button primary" data-op="screen" data-value="editor"{(icon("edit"))"Customize workspace"}}
            _=>{}
        }}}        dl class="module-metadata"{div{dt{"Version"}dd{"v"(m["version"].as_u64().unwrap_or(1))}}div{dt{"Publisher"}dd{(text(m,"publisher"))}}div{dt{"Source"}dd{(if flag(m,"bundled"){"Included with Neutrino"}else{"Local / imported"})}}div{dt{"Status"}dd{(if flag(m,"enabled"){"Active"}else if flag(m,"installed"){"Disabled"}else{"Not installed"})}}}
        @if !text(m,"providerName").is_empty(){p class="module-provider"{(text(m,"providerName"))" is the current provider for this feature."}}
        @if !text(m,"permission").is_empty(){section class="module-permission"{h3{"Access"}p{(text(m,"permission"))}}}
        @if !array(&m["dependencies"]).is_empty(){section class="module-dependencies"{h3{"Dependencies"}@for d in array(&m["dependencies"]){span{(d.as_str().unwrap_or(""))}}}}
        @if flag(m,"installed") && !array(&m["settings"]).is_empty(){section class="module-settings"{h3{"Settings"}@for setting in array(&m["settings"]){(module_setting(id,setting))}}}
        @if !flag(m,"installed"){p class="field-help"{"Install this module to configure it."}}
        @if !array(&s.snapshot["moduleCatalogs"]).is_empty(){details class="module-catalogs"{summary{"Imported catalogs"}@for c in array(&s.snapshot["moduleCatalogs"]){div class="list-row"{span{(c.as_str().unwrap_or(""))}button class="button quiet" data-op="native" data-action="removeCatalog" data-id=(c.as_str().unwrap_or("")){"Remove catalog…"}}}}}
    }}
}
fn module_setting(module_id: &str, setting: &Value) -> Markup {
    let id = text(setting, "id");
    let value = &setting["value"];
    html! {div class="module-setting"{@match text(setting,"kind") {
        "toggle"=>{button class="toggle-row" data-op="module-setting" data-id=(module_id) data-key=(id) data-value=((!value.as_bool().unwrap_or(false)).to_string()) data-type="bool" role="switch" aria-checked=(value.as_bool().unwrap_or(false).to_string()){span{strong{(text(setting,"title"))}}span class=(if value.as_bool().unwrap_or(false){"switch on"}else{"switch"}){span{}}}}
        "choice"=>{label class="field"{span{(text(setting,"title"))}select id=(format!("module-{module_id}-{id}")) data-module-setting=(id) data-module-id=(module_id){@for choice in array(&setting["choices"]){option value=(choice.as_str().unwrap_or("")) selected[*choice==*value]{(choice.as_str().unwrap_or(""))}}}}}
        "integer"=>{label class="field"{span{(text(setting,"title"))}input id=(format!("module-{module_id}-{id}")) type="number" min="0" max="200000" value=(value.as_i64().unwrap_or(0)) data-module-setting=(id) data-module-id=(module_id);}}
        _=>{label class="field"{span{(text(setting,"title"))}input id=(format!("module-{module_id}-{id}")) value=(value.as_str().unwrap_or("")) maxlength="1000" data-module-setting=(id) data-module-id=(module_id);}}
    }}}
}
fn extensions(s: &Shell) -> Markup {
    html! {div class="extensions-content"{
        p class="section-description"{"Add Chrome extensions, review their permissions, and remove them whenever you like."}
        div class="button-row"{button class="button primary" data-op="installExtension" disabled[!flag(&s.snapshot,"blinkAvailable")]{"Open extension manager"}button class="button" data-op="webStore" disabled[!flag(&s.snapshot,"blinkAvailable")]{"Chrome Web Store"}}
        @if !flag(&s.snapshot,"blinkAvailable"){(empty("Extensions aren’t included in this build","Download the full Neutrino app to use Chrome extensions.","grid"))button class="button primary" data-op="navigate" data-value="https://github.com/starharbor2491/neutrino-browser/releases"{"Get the full app"}}
        @else {p class="field-help"{"The manager opens in a Neutrino tab. Enable developer mode there to load a local extension folder."}}
    }}
}

pub(crate) fn menu_item(label: &str, op: &str, value: &str, glyph: &str) -> Markup {
    html! {button class="menu-item" data-op=(op) data-value=(value){(icon(glyph))span{(label)}}}
}
fn menu_title(s: &Shell) -> &'static str {
    match s.menu.as_str() {
        "rename-space" => "Rename Space",
        "new-space" => "New Space",
        "new-folder" => "New folder",
        "new-profile" => "New Profile",
        "find" => "Find on page",
        "add-site" => "Add a site",
        "clear-history" => "Clear history",
        "discard-editor" => "Unsaved changes",
        "reset-modules" => "Reset modules",
        m if m.starts_with("folder:") => "Folder",
        m if m.starts_with("new-folder:") => "New folder inside",
        "add-site:dial" => "Add to Speed Dial",
        m if m.starts_with("delete-") => "Delete",
        _ => "",
    }
}
fn menu(s: &Shell) -> Markup {
    let id = s.menu.split_once(':').map(|x| x.1).unwrap_or("");
    html! {div class=(if s.modal_menu(){"menu-scrim modal-menu"}else{"menu-scrim anchored-menu"}) data-dismiss="true"{section class="popover-menu" data-menu=(s.menu.as_str()) role="dialog" aria-modal=(s.modal_menu().to_string()) aria-label=(if s.menu=="notes-scope"{"Notes scope"}else{"Browser options"}){@if s.modal_menu() || ["rename-space","new-space","new-folder","new-profile","find","add-site","add-site:dial"].contains(&s.menu.as_str()) || s.menu.starts_with("folder:") || s.menu.starts_with("new-folder:") || crate::views::menu_title(&s.menu).is_some(){header{strong{(crate::views::menu_title(&s.menu).unwrap_or(menu_title(s)))}(button("Close","escape","close"))}}
        @if let Some(markup) = crate::views::menus(s, id) {(markup)} @else {
        @match s.menu.as_str(){
            "workspaces"=>{div class="menu-label"{"Spaces"}@for (index,space) in array(&s.snapshot["spaces"]).iter().filter(|v|v["profileID"]==s.snapshot["session"]["profileID"]).enumerate(){button class="menu-item" data-op="switchSpace" data-id=(text(space,"id")) aria-current=[(space["id"]==s.snapshot["session"]["spaceID"]).then_some("true")]{span class="space-symbol menu-space" data-tone=(index%5){(text(space,"name").chars().next().unwrap_or('S'))}span{(text(space,"name"))}@if space["id"]==s.snapshot["session"]["spaceID"]{(icon("check"))}}}div class="menu-separator"{}(menu_item("New Space","menu","new-space","plus"))}
            "shields"=>{@let site=host(text(s.active(),"url"));@let up=flag(&s.snapshot["preferences"],"blockTrackers")&&!shields_lowered(s);
                div class="shields-panel"{strong{(site)}@if let Some(n) = s.snapshot["blockedCount"].as_u64().filter(|_| up) {p class="shields-count"{strong{(n)}" requests blocked on this page"}}p{(if !flag(&s.snapshot["preferences"],"blockTrackers"){"Shields are off for every site."}else if up{"Shields are up. Ads and trackers are blocked on this site."}else{"Shields are down. Nothing is blocked on this site."})}
                    @if flag(&s.snapshot["preferences"],"blockTrackers"){button class="toggle-row" data-op="shields-site" role="switch" aria-checked=(up.to_string()){span{strong{"Shields for this site"}}span class=(if up{"switch on"}else{"switch"}){span{}}}}
                    button class="menu-item" data-op="screen" data-value="settings" data-section="privacy"{(icon("settings"))span{"Shields settings"}}}
            }
            m if m.starts_with("add-site")=>{label class="field"{span{"Site address"}input id="name-input" data-name="true" value=(s.name.as_str()) placeholder="example.com" maxlength="2000" autocomplete="off" spellcheck="false";}button class="button primary" data-op="addSite" disabled[s.name.is_empty()]{"Add"}p class="field-help"{(if m=="add-site:dial" {"Sites you add are saved in the Speed Dial bookmarks folder."} else {"Sites you add are saved as bookmarks."})}}
            "notes-scope"=>{@for (value,label) in [("space","This Space"),("all","All notes")]{button class="menu-item" data-op="native" data-action="notesScope" data-value=(value){(icon(if text(&s.snapshot,"notesScope")==value{"check"}else{"folder"}))span{(label)}}}}
            "split-choose"=>{div class="menu-label"{"Open beside this page"}@for t in s.tabs().iter().filter(|t|t["id"]!=s.active()["id"] && !text(t,"url").is_empty()){button class="menu-item" data-op="split-with" data-id=(text(t,"id")){(site(t))span{(text(t,"title"))}}}@if s.tabs().iter().filter(|t|!text(t,"url").is_empty()).count()<2{p class="field-help"{"Open a second page, then choose it here."}}}
            "space"=>{div class="menu-group"{(menu_item("New folder","menu","new-folder","folder"))@if crate::features::on(s, "sessions") {(menu_item("Save tabs as session…","menu","save-session","download"))}button class="menu-item" data-op="screen" data-value="library" data-section="archive"{(icon("history"))span{"Archived tabs"}}}
                @if crate::features::on(s, "tidy-tabs") {div class="menu-separator"{}
                button class="menu-item menu-item-detail" data-op="tidy-tabs" disabled[s.private()]{(icon("spark"))span{"Tidy tabs into folders"small{"Sends tab titles and sites to your AI provider"}}}}
                div class="menu-separator"{}
                div class="menu-group"{(menu_item("Rename Space","menu","rename-space","edit"))(menu_item("Icon and colors…","menu","space-style","appearance"))(menu_item("Edit layout","screen","editor","sidebar"))(menu_item("New Space","menu","new-space","plus"))}
                div class="menu-separator"{}
                button class="menu-item danger" data-op="menu" data-value=(format!("delete-space:{}",text(&s.snapshot["session"],"spaceID"))) disabled[s.private() || array(&s.snapshot["spaces"]).iter().filter(|v|v["profileID"]==s.snapshot["session"]["profileID"]).count()<2]{(icon("trash"))span{"Delete Space…"}}}
            "rename-space"=>{label class="field"{span{"Space name"}input id="name-input" data-name="true" value=(s.name.as_str()) maxlength="80";}button class="button primary" data-op="renameSpace" data-id=(text(&s.snapshot["session"],"spaceID")) disabled[s.name.is_empty()]{"Save name"}}
            "find"=>{form data-form="find"{label class="field"{span{"Find on this page"}input name="find" id="find-input" type="search" autocomplete="off";}button class="button primary" type="submit"{"Find next"}}p class="field-help"{"Matches are highlighted on the page."}}
            "new-space"|"new-folder"|"new-profile"=>{label class="field"{span{(if s.menu=="new-folder"{"Folder name"}else if s.menu=="new-profile"{"Profile name"}else{"Space name"})}input id="name-input" data-name="true" value=(s.name.as_str()) placeholder="Give it a name" maxlength="80" autocomplete="off";}button class="button primary" data-op=(if s.menu=="new-folder"{"createFolder"}else if s.menu=="new-profile"{"createProfile"}else{"createSpace"}) disabled[s.name.is_empty()]{"Create"}}
            "profiles"=>{@for p in array(&s.snapshot["profiles"]){button class="menu-item" data-op="native" data-action="switchProfile" data-id=(text(p,"id")) disabled[s.private()]{(icon("user"))(text(p,"name"))}}button class="menu-item" data-op="screen" data-value="settings" data-section="profiles"{(icon("settings"))"Manage Profiles"}}
            "clear-history"=>{p{"Clear saved history for this Profile? Your bookmarks, tabs and website sign-ins are kept."}(action("Clear history","clearHistory",true))}
            "discard-editor"=>{p{"You have unsaved appearance changes."}div class="button-row"{(action("Keep editing","escape",false))(action("Discard changes","editor-cancel",false))(action("Save changes","editor-save",true))}}
            "reset-modules"=>{p{"Stop optional modules? A local backup and your saved data are kept."}(action("Reset modules","resetModules",true))}
            _=>{@if s.menu.starts_with("delete-setup:"){p{"Delete this saved setup? Spaces using it will use your app appearance."}button class="button primary" data-op="editor-remove-named" data-id=(id){"Delete setup"}} @else if s.menu.starts_with("delete-credential:"){p{"Delete this saved login from this Profile’s Keychain?"}button class="button primary" data-op="native" data-action="credentialDelete" data-id=(id){"Delete login"}} @else if s.menu.starts_with("delete-note:"){p{"Delete this note? This cannot be undone."}button class="button primary" data-op="native" data-action="deleteNote" data-id=(id){"Delete note"}} @else if s.menu.starts_with("tab:"){ @if let Some(t)=s.tabs().iter().find(|t|text(t,"id")==id){
                (crate::views::tab_menu(s, t))
                div class="menu-separator"{}div class="menu-label"{"Move to"}@if flag(t,"pinned") || !text(t,"folderID").is_empty(){button class="menu-item" data-op="move-tab" data-id=(id) data-group="today"{(icon("sidebar"))"Tabs"}}@for f in array(&s.snapshot["folders"]).iter().filter(|f|f["id"]!=t["folderID"]){button class="menu-item" data-op="move-tab" data-id=(id) data-group="folder" data-folder-id=(text(f,"id")){(icon("folder"))(text(f,"name"))}}
                @for (index,space) in array(&s.snapshot["spaces"]).iter().filter(|v|v["profileID"]==s.snapshot["session"]["profileID"]).enumerate().filter(|(_,v)|v["id"]!=s.snapshot["session"]["spaceID"]){button class="menu-item" data-op="move-space" data-id=(id) data-space-id=(text(space,"id")){span class="space-symbol menu-space" data-tone=(index%5){(text(space,"name").chars().next().unwrap_or('S'))}span{(text(space,"name"))}}}
                
            }} @else if s.menu.starts_with("new-folder:"){label class="field"{span{"Folder name"}input id="name-input" data-name="true" value=(s.name.as_str()) placeholder="Give it a name" maxlength="80" autocomplete="off";}button class="button primary" data-op="createFolder" data-id=(id) disabled[s.name.is_empty()]{"Create"}}
            @else if s.menu.starts_with("folder:"){label class="field"{span{"Rename folder"}input data-name="true" value=(s.name.as_str()) placeholder="New name" maxlength="80"; }button class="button" data-op="renameFolder" data-id=(id) disabled[s.name.is_empty()]{"Rename"}(crate::views::folder_menu_extra(id, array(&s.snapshot["folders"]).iter().find(|f|text(f,"id")==id).map(|f|text(f,"color")).unwrap_or("")))(folder_nesting(s, id))button class="menu-item" data-op="deleteFolder" data-id=(id){(icon("close"))"Remove folder; keep its tabs"}}
            }
        }
        }
    }}}
}
