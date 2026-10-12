// SPDX-License-Identifier: MPL-2.0
use crate::state::{array, flag, text, Shell};
use maud::{html, Markup};
use serde_json::Value;

fn icon_path(name: &str) -> &'static str {
    match name {
        "back"=>"m14 5-7 7 7 7", "forward"=>"m10 5 7 7-7 7", "down"=>"m6 9 6 6 6-6", "close"=>"m6 6 12 12M18 6 6 18",
        "plus"=>"M12 5v14M5 12h14", "search"=>"M20 20l-5-5M10 3a7 7 0 1 0 0 14 7 7 0 0 0 0-14",
        "reload"=>"M20 7v5h-5M19 12a7 7 0 1 0-2 5M20 12l-2-6", "check"=>"m5 12 4 4L19 6", "more"=>"M5 12h.01M12 12h.01M19 12h.01",
        "sidebar"=>"M4 4h16v16H4zM9 4v16", "split"=>"M4 4h16v16H4zM12 4v16", "folder"=>"M3 7V5h7l2 3h9v12H3V7z",
        "bookmark"=>"M6 3h12v18l-6-4-6 4V3z", "history"=>"M3 11a9 9 0 1 1 2 7M3 5v6h6M12 7v5l3 2",
        "download"=>"M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5", "settings"=>"M4 7h16M4 17h16M8 4v6M16 14v6",
        "globe"=>"M3 12h18M12 3c-6 5-6 13 0 18 6-5 6-13 0-18M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18",
        "lock"=>"M7 10V7a5 5 0 0 1 10 0v3M5 10h14v11H5zM12 14v3", "shield"=>"M12 3 3 7v6c0 4 9 8 9 8s9-4 9-8V7L12 3zm-5 9 3 3 6-6",
        "pin"=>"m9 3 8 0-1 6 3 4H5l3-4 1-6M12 13v8", "edit"=>"m4 16 12-12 4 4L8 20H4v-4M13 7l4 4",
        "sun"=>"M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1 1M18 18l1 1M5 19l1-1M18 6l1-1",
        "moon"=>"M20 15A9 9 0 0 1 9 4a9 9 0 1 0 11 11", "spark"=>"m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5L12 3z",
        "undo"=>"M4 5v6h6M4 11a8 8 0 1 1 2 7", "arrow"=>"M5 12h14m-5-5 5 5-5 5", "user"=>"M12 3a4 4 0 1 0 0 8 4 4 0 0 0 0-8M4 21v-3a6 6 0 0 1 6-5h4a6 6 0 0 1 6 5v3",
        "grid"=>"M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h7v7h-7z", "external"=>"M14 3h7v7M21 3 10 14M10 3H3v18h18v-7",
        "grip"=>"M8 5h.01M16 5h.01M8 12h.01M16 12h.01M8 19h.01M16 19h.01", "key"=>"M14 3a7 7 0 1 0 7 7 7 7 0 0 0-7-7M9 15l-6 6H1v-3l6-6M17 7h.01",
        "book"=>"M3 4h7l2 2 2-2h7v16h-7l-2 2-2-2H3V4zM12 6v16", "activity"=>"M2 12h5l3-8 4 16 3-8h5", "camera"=>"M3 7h5l2-3h4l2 3h5v14H3V7zM8 14a4 4 0 1 0 8 0 4 4 0 0 0-8 0",
        _=>"M5 5h14v14H5z"
    }
}
fn icon(name: &str) -> Markup {
    html! {svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" {use href=(format!("#glyph-{name}"));}}
}
fn icon_definitions(s: &Shell) -> Markup {
    let names = [
        "back", "forward", "down", "close", "plus", "search", "reload", "check", "more", "sidebar",
        "split", "folder", "bookmark", "history", "download", "settings", "globe", "lock",
        "shield", "pin", "edit", "sun", "moon", "spark", "undo", "arrow", "user", "grid",
        "external", "grip", "key", "book", "activity", "camera",
    ];
    html! {svg class="icon-definitions" aria-hidden="true"{defs{@for name in names{
        @let key = match name {"bookmark"=>"bookmarks","grid"=>"modules",v=>v};
        @let value = text(&s.snapshot["icons"],key);
        @let image = text(&s.snapshot["iconImages"],key);
        @let filled = value.ends_with(".fill") || (value.is_empty() && text(&s.config()["theme"],"iconStyle")=="filled");
        symbol id=(format!("glyph-{name}")) viewBox="0 0 24 24"{
            @if image.starts_with("data:image/png;base64,") && image.len()<12000{mask id=(format!("mask-{name}")) maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24" style="mask-type:alpha"{image href=(image) x="0" y="0" width="24" height="24";}rect x="0" y="0" width="24" height="24" fill="currentColor" stroke="none" mask=(format!("url(#mask-{name})"));}
            @else if filled && ["back","forward","reload"].contains(&name){circle cx="12" cy="12" r="10" fill="currentColor" stroke="none";path d=(icon_path(name)) stroke="var(--rail)" fill="none";}
            @else {path d=(icon_path(name)) fill=(if filled && ["bookmark","grid","folder","pin"].contains(&name){"currentColor"}else{"none"});}
        }
    }}}}
}
fn theme_style(s: &Shell) -> String {
    let t = &s.config()["theme"];
    let mut style = format!("--component-radius:{}px;--font-scale:{};--spacing-scale:{};--theme-border:{}px;--theme-shadow:{}",t["cornerRadius"].as_f64().unwrap_or(6.).clamp(0.,24.),t["fontScale"].as_f64().unwrap_or(1.).clamp(0.85,1.4),t["spacingScale"].as_f64().unwrap_or(1.).clamp(0.75,1.5),t["borderWidth"].as_f64().unwrap_or(1.).clamp(0.,2.),t["shadowStrength"].as_f64().unwrap_or(0.).clamp(0.,1.));
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
            a["fontScale"].as_f64().unwrap_or(1.).clamp(0.85, 1.4),
            if text(a, "density") == "compact" {
                0.85
            } else {
                1.
            }
        ));
    }
    style
}
fn button(label: &str, op: &str, glyph: &str) -> Markup {
    html! {button class="icon-button" data-op=(op) title=(label) aria-label=(label) {(icon(glyph))}}
}
fn action(label: &str, op: &str, primary: bool) -> Markup {
    html! {button class=(if primary{"button primary"}else{"button"}) data-op=(op) {(label)}}
}
fn field(label: &str, key: &str, value: &str, invalid: bool) -> Markup {
    html! {label class="field" {span{(label)}input id=(format!("setup-{key}")) data-setup=(key) value=(value) maxlength="80" autocomplete="off" aria-invalid=(invalid.to_string()) aria-describedby=[invalid.then(||format!("error-{key}"))];
        @if invalid {span class="field-error" id=(format!("error-{key}")){"Enter a name to continue."}}
    }}
}

fn toggle(label: &str, detail: &str, key: &str, value: bool, setup: bool) -> Markup {
    html! {button class="toggle-row" data-op=(if setup{"setup-field"}else{"preference"}) data-key=(key) data-value=((!value).to_string()) data-type="bool" role="switch" aria-checked=(value.to_string()) {span {strong{(label)}@if !detail.is_empty(){small{(detail)}}} span class=(if value{"switch on"}else{"switch"}) {span{}}}}
}
fn tab_visible(tab: &Value, s: &Shell) -> bool {
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
fn site(tab: &Value) -> Markup {
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

fn tab_row(t: &Value, s: &Shell, preview: bool) -> Markup {
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
    html! {div class=(if selected{"tab-row active"}else{"tab-row"}) data-tab=(text(t,"id")) data-group=(group) data-folder=(text(t,"folderID")) draggable=((!preview).to_string()) {
        @if children {button class="branch" data-op="toggleBranch" data-id=(text(t,"id")) aria-label=(format!("{} {}",if flag(t,"collapsed"){"Expand"}else{"Collapse"},text(t,"title"))) {(icon(if flag(t,"collapsed"){"forward"}else{"down"}))}}
        button class="tab-select" data-op="selectTab" data-id=(text(t,"id")) aria-current=[selected.then_some("page")] title=(text(t,"url")) {(site(t)) span{(text(t,"title"))}}
        button class="tab-close" data-op="closeTab" data-id=(text(t,"id")) aria-label=(format!("Close {}",text(t,"title"))) {(icon("close"))}
        button class="tab-menu" data-op="menu" data-value=(format!("tab:{}",text(t,"id"))) aria-label=(format!("Options for {}",text(t,"title"))) {(icon("more"))}
    }}
}
fn tab_groups(s: &Shell, preview: bool) -> Markup {
    html! {
        div class="tab-group pins" data-drop-group="pinned" aria-label="Pinned tabs" {
            div class="group-label" {span{"Pinned"}span class="drag-hint"{"Drop to pin"}}
            @for t in s.tabs().iter().filter(|t|flag(t,"pinned")&&tab_visible(t,s)){(tab_row(t,s,preview))}
            @if !s.tabs().iter().any(|t|flag(t,"pinned")){div class="empty-pins"{"Keep your go-to tabs here"}}
        }
        @for f in array(&s.snapshot["folders"]) {div class="folder-group" data-drop-group="folder" data-folder=(text(f,"id")) {
            div class="folder-heading" draggable=((!preview && !s.private()).to_string()) data-folder-source=(text(f,"id")) tabindex="0" aria-label=(format!("Folder {}. Drag or use Option Shift arrow keys to reorder.",text(f,"name"))) {button data-op="toggleFolder" data-id=(text(f,"id")) aria-expanded=((!flag(f,"collapsed")).to_string()) {(icon(if flag(f,"collapsed"){"forward"}else{"down"}))(icon("folder"))span{(text(f,"name"))}}
                button class="icon-button" data-op="menu" data-value=(format!("folder:{}",text(f,"id"))) aria-label=(format!("Options for {}",text(f,"name"))) {(icon("more"))}}
            @if !flag(f,"collapsed"){@for t in s.tabs().iter().filter(|t|!flag(t,"pinned")&&t["folderID"]==f["id"]&&tab_visible(t,s)){(tab_row(t,s,preview))}
                @if !s.tabs().iter().any(|t|t["folderID"]==f["id"]){div class="folder-empty"{"Drop tabs here"}}}
        }}
        div class="tab-group today" data-drop-group="today" aria-label="Unpinned tabs" {
            div class="group-label"{span{"Today"}@if !s.tab_undo.is_empty(){button data-op="undo-tabs" title="Undo the last tab move"{(icon("undo"))"Undo"}}}
            @for t in s.tabs().iter().filter(|t|!flag(t,"pinned")&&text(t,"folderID").is_empty()&&tab_visible(t,s)){(tab_row(t,s,preview))}
            button class="new-tab" data-op="newTab" {(icon("plus"))span{"New tab"}kbd{"⌘T"}}
            div class="drop-end" data-drop-group="today" {}
        }
    }
}
fn spaces(s: &Shell) -> Markup {
    html! {div class="spaces" aria-label="Spaces" {
        @for (index,space) in array(&s.snapshot["spaces"]).iter().filter(|v|v["profileID"]==s.snapshot["session"]["profileID"]).enumerate() {button class=(if space["id"]==s.snapshot["session"]["spaceID"]{"space-button selected"}else{"space-button"}) data-op="switchSpace" data-id=(text(space,"id")) data-space=(text(space,"id")) draggable=((!s.private()).to_string()) title=(text(space,"name")) aria-label=(format!("Switch to {}",text(space,"name"))) aria-pressed=((space["id"]==s.snapshot["session"]["spaceID"]).to_string()) disabled[s.private()] {span class=(format!("space-symbol color-{}",index%5)){(text(space,"name").chars().next().unwrap_or('S'))}}}
        button class="space-button" data-op="menu" data-value="new-space" aria-label="Create a Space" disabled[s.private()] {(icon("plus"))}
    }}
}
fn rail_navigation(s: &Shell) -> Markup {
    html! {div class="rail-navigation" {
        (button("Back","back","back"))(button("Forward","forward","forward"))
        (button(if flag(&s.snapshot,"loading"){"Stop loading"}else{"Reload page"},if flag(&s.snapshot,"loading"){"stop"}else{"reload"},if flag(&s.snapshot,"loading"){"close"}else{"reload"}))
    }}
}
fn location(s: &Shell) -> Markup {
    html! {form class="location" data-form="address" aria-label="Address bar" {(icon(if s.private(){"shield"}else if text(s.active(),"url").starts_with("https:"){"lock"}else{"search"}))input id="address-input" name="address" value=(text(s.active(),"url")) placeholder="Search or enter URL" autocomplete="off" spellcheck="false" aria-label="Search or enter URL";}}
}
fn rail(s: &Shell, preview: bool) -> Markup {
    let horizontal = ["top", "bottom"].contains(&text(&s.config()["layout"], "tabs"));
    let bottom = text(&s.config()["layout"], "navigation") == "bottom";
    html! {aside class="workspace-rail" aria-label="Workspace" {
        div class="rail-top" {div class="traffic-clearance" data-window-drag="true"{}
            span class="rail-drag-fill" data-window-drag="true"{}
            button class="icon-button" data-op="sidebar" aria-label="Hide sidebar"{(icon("sidebar"))}
            button class="icon-button" data-op="menu" data-value="browser" aria-label="Browser menu"{(icon("more"))}
        }
        @if !bottom && !horizontal {(location(s))}
        @if !preview{(feedback(s))}
        div class="space-heading"{span class="space-dot"{}strong{(if s.private(){"Private"}else{text(&s.snapshot,"spaceName")})}button class="icon-button" data-op="menu" data-value="space" aria-label="Space options"{(icon("more"))}}
        @if horizontal {div class="horizontal-guide"{p{"Tabs live "(if text(&s.config()["layout"],"tabs")=="top"{"above your page."}else{"below your page."})}button class="new-tab" data-op="newTab"{(icon("plus"))"New tab"}button class="new-tab" data-op="screen" data-value="library" data-section="archive"{(icon("folder"))"Archived tabs"}}}
        @else {div class="tabs-scroll"{(tab_groups(s,preview))}}
        @if bottom && !horizontal {div class="rail-bottom-nav"{(location(s))(rail_navigation(s))}}
        div class="rail-footer"{(spaces(s))nav class="rail-destinations" aria-label="Browser tools"{button class=(if s.screen=="library"{"selected"}else{""}) data-op="screen" data-value="library" data-section="bookmarks"{(icon("bookmark"))"Library"}button class=(if s.screen=="modules"{"selected"}else{""}) data-op="screen" data-value="modules"{(icon("grid"))"Modules"}}
            div class="rail-tools"{button class="icon-button" data-op="screen" data-value="settings" aria-label="Settings"{(icon("settings"))}button class="icon-button" data-op="screen" data-value="extensions" aria-label="Extensions"{(icon("grid"))}span class="spacer"{}button class="icon-button" data-op="screen" data-value="editor" aria-label="Customize appearance"{(icon("edit"))}button class="avatar" data-op="menu" data-value="profiles" title=(text(&s.snapshot,"profileName")) aria-label=(format!("Profile: {}",text(&s.snapshot,"profileName"))){(icon("user"))}}
        }
    }}
}

fn host(url: &str) -> String {
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
fn start(s: &Shell) -> Markup {
    html! {section class="start-surface" aria-label="New tab" {
        div class="start-inner" {
            div class="eyebrow"{(if s.private(){"PRIVATE WINDOW"}else{text(&s.snapshot,"spaceName")})}
            img class="start-logo" src="neutrino.svg" alt="";
            h1{(if s.private(){"Private browsing"}else{"Neutrino"})}
            form class="start-search" data-form="address" {(icon("search"))input id="start-input" name="address" type="search" placeholder="Search or enter a URL" aria-label="Search or enter a URL" autocomplete="off";button class="icon-button" type="submit" aria-label="Go"{(icon("arrow"))}}
            @if s.private(){p class="start-detail"{"Tabs and history stay temporary. Downloads remain on your Mac."}}
            @if !array(&s.snapshot["bookmarks"]).is_empty() {
                div class="bookmark-grid" {@for b in array(&s.snapshot["bookmarks"]).iter().take(8) {
                    button data-op="navigate" data-value=(text(b,"url")) title=(text(b,"url")){(site(b))span{(text(b,"title"))}}
                }}
            } @else if !s.private() {
                div class="start-hint" {button data-op="importBookmarks"{(icon("bookmark"))"Import bookmarks"}button data-op="screen" data-value="modules"{(icon("grid"))"Modules"}}
            }
            @for widget in array(&s.snapshot["startWidgets"]){aside class="start-widget"{h2{(text(widget,"widgetTitle"))}p{(text(widget,"widgetBody"))}}}
        }
    }}
}

fn horizontal_tabs(s: &Shell, preview: bool) -> Markup {
    html! {div class="horizontal-tabs" {
        div class="horizontal-group" data-drop-group="pinned" {
            span class="horizontal-group-label" title="Pinned tabs"{(icon("pin"))}
            @for t in s.tabs().iter().filter(|t|flag(t,"pinned")){(tab_row(t,s,preview))}
        }
        @for folder in array(&s.snapshot["folders"]) {
            div class="horizontal-group" data-drop-group="folder" data-folder=(text(folder,"id")) {
                button class="horizontal-group-label" data-op="toggleFolder" data-id=(text(folder,"id")) aria-expanded=((!flag(folder,"collapsed")).to_string()){(icon("folder"))(text(folder,"name"))}
                button class="icon-button folder-options" data-op="menu" data-value=(format!("folder:{}",text(folder,"id"))) aria-label=(format!("Options for {}",text(folder,"name"))){(icon("more"))}
                @if !flag(folder,"collapsed") {@for t in s.tabs().iter().filter(|t|!flag(t,"pinned")&&t["folderID"]==folder["id"]){(tab_row(t,s,preview))}}
            }
        }
        div class="horizontal-group" data-drop-group="today" {
            @for t in s.tabs().iter().filter(|t|!flag(t,"pinned")&&text(t,"folderID").is_empty()){(tab_row(t,s,preview))}
            (button("New tab","newTab","plus"))
        }
    }}
}

fn browser(s: &Shell, preview: bool) -> Markup {
    let placement = text(&s.config()["layout"], "tabs");
    let horizontal = ["top", "bottom"].contains(&placement);
    let panel = preview && s.edit_component == "panels";
    let width = s.config()["layout"]["tabsWidth"]
        .as_f64()
        .unwrap_or(240.)
        .clamp(200., 340.);
    html! {div class=(format!("browser-shell placement-{} {} {} {}",placement,if panel{"with-library"}else{""},if s.sidebar_hidden{"rail-hidden"}else{""},if preview{"editing-preview"}else{""})) style=(format!("--rail-width:{width}px")) data-navigation=(text(&s.config()["layout"],"navigation")) data-panel=(text(&s.config()["layout"],"sidebar")) {
        div class="window-grip" data-window-drag="true"{}
        (rail(s,preview))
        @if panel {aside class="library-panel" aria-label="Library" {header{h2{"Library"}(button("Close library","escape","close"))}(library(s))}}
        @if !horizontal && !s.sidebar_hidden {div class="rail-resizer" role="separator" tabindex="0" aria-label="Sidebar width" aria-orientation="vertical" aria-valuemin="200" aria-valuemax="340" aria-valuenow=(width) data-resize="rail" {}}
        main class="browser-main" {header class="page-toolbar" {
            div class="toolbar-controls"{(rail_navigation(s))}
            @if s.sidebar_hidden || horizontal || panel { (button(if panel{"Return to tabs"}else{"Show sidebar"},if panel{"reveal-workspace"}else{"sidebar"},"sidebar")) }
            span class="toolbar-drag" data-window-drag="true"{}
            @if horizontal {(location(s))}@else {button class="page-identity" data-op="focus-address" title=(text(s.active(),"url")){(icon(if text(s.active(),"url").starts_with("https:"){"lock"}else{"globe"}))span{(if text(s.active(),"url").is_empty(){"New tab".into()}else{host(text(s.active(),"url"))})}}}
            span class="toolbar-drag" data-window-drag="true"{}
            div class="page-actions"{@if flag(&s.snapshot,"focusMode") || array(&s.snapshot["modules"]).iter().any(|m|flag(m,"enabled") && text(m,"capability")=="focusMode"){button class=(if flag(&s.snapshot,"focusMode"){"button focus-exit"}else{"icon-button"}) data-op="native" data-action="toggleFocus" aria-label=(if flag(&s.snapshot,"focusMode"){"Exit Focus mode"}else{"Enter Focus mode"}) title="Focus mode"{(icon("moon"))@if flag(&s.snapshot,"focusMode"){"Exit Focus"}}}(button("Save bookmark","bookmark","bookmark"))(button("Split view","split","split"))button class="icon-button" data-op="screen" data-value="assistant" aria-label="Page assistant"{(icon("spark"))}}
        }
        @if s.sidebar_hidden && !preview {(feedback(s))}
        @if horizontal && placement=="top"{(horizontal_tabs(s,preview))}
        @if flag(&s.config()["layout"],"bookmarksBar"){div class="bookmarks-bar"{@for b in array(&s.snapshot["bookmarks"]){button data-op="navigate" data-value=(text(b,"url")){(text(b,"title"))}}}}
        div class="page-frame"{
            @if !preview && !["browse","editor"].contains(&s.screen.as_str()) {(utility_page(s))}
            @else if !s.snapshot["session"]["split"].is_null(){div class="split-canvas" data-axis=(text(&s.config()["layout"],"split")){
                @for id in [&s.snapshot["session"]["split"]["first"],&s.snapshot["session"]["split"]["second"]] {
                    @let identifier=id.as_str().unwrap_or("");
                    section class="split-pane" {div class="split-label"{button data-op="selectTab" data-id=(identifier){(s.tabs().iter().find(|t|t["id"]==*id).map(|t|text(t,"title")).unwrap_or("New tab"))}(button("Exit split view","unsplit","close"))}
                        @if let Some(error)=s.snapshot["pageErrors"][identifier].as_str(){(page_error(error,identifier))}
                        @else {div class="native-page" data-page=(identifier){@if preview {div class="preview-webpage"{p{"Your page"}}}}}
                    }
                }
            }} @else if let Some(message)=s.snapshot["pageError"].as_str(){(page_error(message,text(s.active(),"id")))}
            @else if !text(s.active(),"url").is_empty() {div class="native-page" data-page=(text(s.active(),"id")){@if preview {div class="preview-webpage"{p{"Your page"}small{(host(text(s.active(),"url")))}}}}}
            @else {(start(s))}
        }
        @if horizontal && placement=="bottom"{(horizontal_tabs(s,preview))}
        @if flag(&s.snapshot,"loading"){div class="loading-line" role="progressbar" aria-label="Loading page" {}}
        }
    }}
}

fn page_error(message: &str, id: &str) -> Markup {
    html! {div class="page-error"{(icon("globe"))h2{"This page couldn’t open"}p{(message)}div class="button-row"{button class="button primary" data-op="native" data-action="reloadTab" data-id=(id){"Try again"}button class="button" data-op="native" data-action="useWebKit" data-id=(id){"Try WebKit"}}}}
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
    html! {div class="app-shell" style=(theme_style(s)) data-design=(text(&s.config()["theme"],"design")) data-transparency=(flag(&s.config()["theme"],"transparency").to_string()) data-typeface=(text(&s.config()["theme"],"typography")) data-focus=(flag(&s.snapshot,"focusMode").to_string()) data-focus-hidden=(array(&s.snapshot["focusHidden"]).iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" ")) data-mode=(mode) data-accent=(accent) data-density=(text(&s.config()["theme"],"density")) data-reduced-motion=(flag(&s.config()["theme"],"reducedMotion").to_string()) {
        (icon_definitions(s))@if flag(&s.snapshot,"downloadsWindow"){main class="downloads-window"{header{h1{"Downloads"}(button("Close downloads","escape","close"))}(library(s))}} @else if s.onboarding(){(setup(s))} @else if s.screen=="editor"{(editor(s))} @else {(browser(s,false))
        }
        @if s.palette{(palette(s))}
        @if !s.menu.is_empty(){(menu(s))}

    }}
}
fn feedback(s: &Shell) -> Markup {
    let notice = if !s.notice.is_empty() {
        s.notice.as_str()
    } else {
        text(&s.snapshot, "notice")
    };
    html! {@if !notice.is_empty(){div class="rail-feedback" role="status" data-transient=((notice.starts_with("Tab moved.") || notice.ends_with("order updated.")).to_string()){span{(notice)}@if notice.starts_with("Tab moved.") || notice.ends_with("order updated."){button data-op="undo-tabs"{"Undo"}}button class="icon-button" data-op="dismiss-notice" aria-label="Dismiss message"{(icon("close"))}}}}
}
fn utility_page(s: &Shell) -> Markup {
    html! {section class="utility-screen" data-screen=(s.screen.as_str()) aria-label=(s.screen.as_str()){
        header class="utility-header"{h1{(match s.screen.as_str(){"settings"=>"Settings","library"=>"Library","modules"=>"Modules","extensions"=>"Extensions","assistant"=>"Assistant","reader"=>"Reader","resources"=>"Resources",_=>"Recovery"})}span class="spacer"{}button class="button quiet" data-op="escape"{(icon("back"))"Back to browsing"}}
        (utility(s))
    }}
}
fn setup(s: &Shell) -> Markup {
    let titles = [
        "Welcome to Neutrino",
        "Set up your workspace",
        "Import your bookmarks",
        "Choose your appearance",
        "Set your defaults",
        "Connect AI, if you want",
        "Ready to browse",
    ];
    let descriptions = [
        "Tabs, Spaces and tools that work together. Set up your browser in a few steps.",
        "Profiles separate website accounts. Spaces organize your tabs within a Profile.",
        "Choose an HTML bookmarks export. You can skip this step.",
        "Start with a layout and color. Customize either later.",
        "Choose your search engine, privacy defaults and built-in modules.",
        "Use an API key, an account or a local model. AI stays off until configured.",
        "Review your choices and open Neutrino.",
    ];
    html! {main class=(format!("onboarding step-{}",s.step)) {
        div class="setup-drag" data-window-drag="true"{}
        aside class="setup-scene" aria-hidden="true" {div class="scene-caption"{span{(["Your browser","Profiles & Spaces","Bookmarks","Appearance","Privacy & modules","Optional AI","All set"][s.step])}}
            div class="mini-browser" data-layout=(text(&s.setup,"layout")){div class="mini-rail"{div class="mini-dots"{i{}i{}i{}}div class="mini-address"{(icon("search"))"Search or enter URL"}strong{(text(&s.setup,"space"))}div class="mini-pin"{(icon("bookmark"))"GitHub"}div class="mini-folder"{(icon("folder"))"Projects"}div class="mini-tab"{(icon("globe"))"Proton"}div class="mini-tab selected"{(icon("grid"))"Modules"}div class="mini-plus"{(icon("plus"))"New tab"}}div class="mini-page"{h2{"Neutrino"}div class="mini-search"{(icon("search"))"Search or enter URL"}div class="mini-module-row"{(icon("bookmark"))(icon("grid"))(icon("shield"))}}}
        }
        section class="setup-content"{header class="setup-header"{span class="wordmark"{img class="brand-icon" src="neutrino.svg" alt="";"neutrino"}}
            div class="setup-copy"{h1 id="setup-heading" tabindex="-1"{(titles[s.step])}p{(descriptions[s.step])}}
            div class="setup-form"{
                @match s.step {
                    0=>{div class="welcome-points"{div{(icon("sidebar"))span{"Keep your tabs in Spaces"}}div{(icon("edit"))span{"Shape the browser around you"}}div{(icon("shield"))span{"Your data stays on your Mac"}}}}
                    1=>{(field("Profile name","profile",text(&s.setup,"profile"),s.invalid_field=="profile"))(field("Your first Space","space",text(&s.setup,"space"),s.invalid_field=="space"))}
                    2=>{button class="import-card" data-op="importBookmarks"{span class="import-symbol"{(icon("download"))}strong{(if flag(&s.snapshot,"imported"){"Bookmarks are in"}else{"Choose bookmarks file"})}span{"HTML export · duplicates skipped"}(icon("arrow"))}p class="field-help"{"Import is optional. Passwords and website sign-ins aren’t included in a bookmarks file."}}
                    3=>{label class="control-label"{"Color"}(swatches(s,true))label class="control-label"{"Appearance"}(segments("setup-field","appearance",text(&s.setup,"appearance"),&[("system","System"),("light","Light"),("dark","Dark")]))label class="control-label"{"Tabs"}(segments("setup-field","layout",text(&s.setup,"layout"),&[("leading","In the sidebar"),("top","Along the top")]))}
                    4=>{label class="control-label"{"Search engine"}(segments("setup-field","search",text(&s.setup,"search"),&[("duckDuckGo","DuckDuckGo"),("google","Google"),("bing","Bing")]))div class="settings-group"{(toggle("Block ads & trackers","Local blocking rules.","blockTrackers",flag(&s.setup,"blockTrackers"),true))(toggle("Block unwanted popups","","blockPopups",flag(&s.setup,"blockPopups"),true))(toggle("Restore tabs on launch","Private tabs stay temporary.","restoreSession",flag(&s.setup,"restoreSession"),true))}details class="setup-modules"{summary{(icon("grid"))"Built-in modules"(icon("down"))}p{"Add or replace tools from Modules in the sidebar."}@for m in array(&s.snapshot["modules"]).iter().filter(|m|flag(m,"installed") && ["notes","reader","focusMode","resourceMonitor"].contains(&text(m,"capability"))).take(5){button class="setup-module-row" data-op="native" data-action="toggleModule" data-id=(text(m,"id")) role="switch" aria-checked=(flag(m,"enabled").to_string()){(icon(module_glyph(text(m,"id"))))span{(text(m,"name"))}span class="module-status"{(if flag(m,"enabled"){"On"}else{"Off"})}}}}}
                    5=>{details class="ai-disclosure"{summary{(icon("spark"))"Set up an AI provider"(icon("down"))}(ai_form(s))}div class="ai-off"{(icon("shield"))p{"AI is off until you connect a provider. You can do this later in Settings."}}}
                    _=>{div class="setup-review"{div{span{"Your Space"}strong{(text(&s.setup,"space"))}}div{span{"Profile"}strong{(text(&s.setup,"profile"))}}div{span{"Search"}strong{(match text(&s.setup,"search"){"google"=>"Google","bing"=>"Bing",_=>"DuckDuckGo"})}}div{span{"Privacy"}strong{(if flag(&s.setup,"blockTrackers"){"Blocking on"}else{"Blocking off"})}}div{span{"Built-in tools"}strong{(array(&s.snapshot["modules"]).iter().filter(|m|flag(m,"enabled") && ["notes","reader","focusMode","resourceMonitor"].contains(&text(m,"capability"))).map(|m|text(m,"name")).collect::<Vec<_>>().join(", "))}}}button class="default-browser" data-op="defaultBrowser"{(icon("globe"))span{"Make Neutrino your default"}(icon("external"))}p class="field-help"{(text(&s.snapshot,"defaultStatus"))}}
                }
            }
            footer class="setup-footer"{(feedback(s))div class="setup-progress" role="progressbar" aria-label="Setup progress" aria-valuemin="1" aria-valuemax="7" aria-valuenow=(s.step+1) aria-valuetext=(format!("Step {} of 7: {}",s.step+1,titles[s.step])){span class="step-count"{(s.step+1)" of 7"}@for i in 0..7{span class=(if i==s.step{"current"}else if i<s.step{"done"}else{""}) aria-hidden="true"{}}}
                div class="setup-actions"{@if s.step>0{button class="button quiet" data-op="setup-back" disabled[s.setup_busy]{(icon("back"))"Back"}}span class="spacer"{}button class="button primary" data-op=(if s.step==6{"setup-finish"}else{"setup-next"}) disabled[s.setup_busy]{(if s.setup_busy{"Saving…"}else if s.step==0{"Get started"}else if s.step==2&&!flag(&s.snapshot,"imported")||s.step==5&&s.snapshot["preferences"]["ai"].is_null(){"Skip for now"}else if s.step==6{"Open Neutrino"}else{"Continue"})(icon("arrow"))}}
            }
        }
    }}
}
fn segments(op: &str, key: &str, selected: &str, items: &[(&str, &str)]) -> Markup {
    html! {div class="segments" role="group"{@for (value,label) in items{button class=(if *value==selected{"selected"}else{""}) data-op=(op) data-key=(key) data-value=(value) aria-pressed=((*value==selected).to_string()){(label)}}}}
}
fn swatches(s: &Shell, setup: bool) -> Markup {
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
            div class="editor-preview"{div class="preview-canvas" inert="" {(browser(s,true))}@for region in ["leading","trailing","top","bottom"]{div class=(format!("dock-target dock-{region}")) data-dock=(region){span{(match region{"leading"=>"Left","trailing"=>"Right","top"=>"Top",_=>"Bottom"})}}}}
            div class="editor-recovery"{button class="icon-button" data-op="editor-undo" title="Undo appearance change" aria-label="Undo appearance change" disabled[s.undo.is_empty()]{(icon("undo"))}button class="icon-button" data-op="editor-redo" title="Redo appearance change" aria-label="Redo appearance change" disabled[s.redo.is_empty()]{(icon("forward"))}button data-op="editor-reset"{"Reset appearance"}span class="editor-feedback" role="status"{(if !s.notice.is_empty(){s.notice.as_str()}else if !text(&s.snapshot,"notice").is_empty(){text(&s.snapshot,"notice")}else{"Changes apply when you save."})}}
        }
        aside class="editor-inspector" id="appearance-controls" hidden[s.expanded_preview]{div class="inspector-section"{h2{"Arrange"}p{"Drag a component, or choose its position."}
            @for (component,label,glyph) in [("tabs","Tabs","sidebar"),("navigation","Navigation","search"),("panels","Library panel","grid")] {div class=(if s.edit_component==component{"component selected"}else{"component"}) draggable="true" data-component=(component){button data-op="editor-select" data-value=(component){(icon(glyph))span{(label)}(icon("grip"))}}}
            div class="position-controls" role="group" aria-label="Component position"{@for (region,label) in [("leading","Left"),("top","Top"),("trailing","Right"),("bottom","Bottom")] { @let valid=s.edit_component=="tabs" || s.edit_component=="navigation"&&["top","bottom"].contains(&region) || s.edit_component=="panels"&&["leading","trailing"].contains(&region);button class=(if text(&s.config()["layout"],match s.edit_component.as_str(){"tabs"=>"tabs","navigation"=>"navigation",_=>"sidebar"})==region{"selected"}else{""}) aria-pressed=((text(&s.config()["layout"],match s.edit_component.as_str(){"tabs"=>"tabs","navigation"=>"navigation",_=>"sidebar"})==region).to_string()) data-op="dock" data-component=(s.edit_component.as_str()) data-region=(region) disabled[!valid]{(label)}}}
            @if s.edit_component=="tabs"{label class="field"{span{"Sidebar width"}input type="range" min="200" max="340" step="4" value=(s.config()["layout"]["tabsWidth"].as_f64().unwrap_or(240.)) data-editor="tabsWidth" aria-label="Sidebar width";}}
        }
        div class="inspector-section"{h2{"Browser appearance"}(swatches(s,false))label class="control-label"{"Mode"}(segments("editor-value","colorMode",text(&s.config()["theme"],"colorMode"),&[("system","System"),("light","Light"),("dark","Dark")]))button class="toggle-row" data-op="editor-value" data-key="reducedMotion" data-value=((!flag(&s.config()["theme"],"reducedMotion")).to_string()) data-type="bool" role="switch" aria-checked=(flag(&s.config()["theme"],"reducedMotion").to_string()){span{strong{"Reduce motion"}}span class=(if flag(&s.config()["theme"],"reducedMotion"){"switch on"}else{"switch"}){span{}}}label class="control-label"{"Density"}(segments("editor-value","density",text(&s.config()["theme"],"density"),&[("comfortable","Roomy"),("compact","Compact")]))}
        div class="inspector-section editor-help"{p class="field-help"{"Drag to arrange. Save when it feels right. Your site identity and recovery controls stay available in every layout."}}
        }
        }
    }}
}
fn palette(s: &Shell) -> Markup {
    let results = s.results();
    html! {div class="palette-scrim" data-dismiss="true"{section class="command-palette" role="dialog" aria-modal="true" aria-label="Search and switch tabs"{div class="palette-grip" data-drag-dialog="true" tabindex="0" role="button" aria-label="Move command palette with arrow keys"{(icon("grip"))span{"Quick navigation"}span class="spacer"{}kbd{"⌘K"}}div class="command-field"{(icon("search"))input id="command-input" type="text" autocomplete="off" spellcheck="false" placeholder="Search tabs, commands or a URL" value=(s.query.as_str()) aria-label="Search, enter a URL, or find a tab" role="combobox" aria-expanded="true" aria-controls="command-results" aria-activedescendant=(format!("result-{}",s.selected_result));kbd{"esc"}}
        div class="command-results" id="command-results" role="listbox"{@for (index,r) in results.iter().enumerate(){button id=(format!("result-{index}")) class=(if index==s.selected_result{"command-result selected"}else{"command-result"}) data-op="select-result" data-index=(index) role="option" aria-selected=((index==s.selected_result).to_string()){(icon(if text(r,"kind")=="tab"{"globe"}else{"search"}))span{strong{(text(r,"title"))}small{(text(r,"detail"))}}span class="result-kind"{(if text(r,"kind")=="tab"{"Switch to tab"}else{"Open"})}}}
        @if results.is_empty(){div class="command-empty"{"Type a website, search, or tab title."}}}
        footer class="command-footer"{span{kbd{"↑"}kbd{"↓"}" to move"}span{kbd{"↵"}" to open"}}
    }}}
}
fn utility(s: &Shell) -> Markup {
    match s.screen.as_str() {
        "resources" => resources(s),
        "settings" => settings(s),
        "library" => library(s),
        "assistant" => assistant(s),
        "reader" => {
            html! {article class="reader-content" {pre{(text(&s.snapshot,"assistantResponse"))}}}
        }
        "extensions" => extensions(s),
        "modules" => modules(s),
        "recovery" => {
            html! {div class="settings-content"{h2{"A way back"}p class="section-description"{"Recover the interface while keeping your browsing data."}
                div class="list-row"{div{strong{"Restore appearance"}small{"Reset the browser default and this Space’s layout."}}(action("Restore layout","restoreLayout",false))}
                div class="list-row"{div{strong{"Reset optional modules"}small{"Keep a local backup and stop optional features."}}button class="button" data-op="menu" data-value="reset-modules"{"Reset modules…"}}
                div class="list-row"{div{strong{"Save your data"}small{"Retry a failed save."}}(action("Retry save","retrySave",false))}
                div class="list-row"{div{strong{"Local backups"}small{"Inspect Neutrino’s data folder."}}(action("Show in Finder","showDataFolder",false))}
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
    html! {div class="settings-layout"{nav class="settings-nav" aria-label="Settings sections"{button data-op="screen" data-value="modules"{(icon("grid"))"Modules"}@for (key,label,glyph) in [("general","General","settings"),("profiles","Profiles","user"),("privacy","Privacy","shield"),("appearance","Appearance","edit"),("ai","AI providers","spark"),("passwords","Passwords","key"),("updates","Updates & engines","download")] {button class=(if s.section==key{"selected"}else{""}) data-op="section" data-value=(key){(icon(glyph))(label)}}}
        div class="settings-content"{@match s.section.as_str(){
            "profiles"=>{h2{"Your Profiles"}p class="section-description"{"Separate website accounts, cookies and extensions. Spaces can share a Profile."}@for p in array(&s.snapshot["profiles"]){div class="list-row"{(icon("user"))div{strong{(text(p,"name"))}small{(if p["id"]==s.snapshot["session"]["profileID"]{"Current Profile"}else{"Separate browsing data"})}}button class="button" data-op="native" data-action="switchProfile" data-id=(text(p,"id")) disabled[s.private()]{"Switch"}}}button class="button" data-op="menu" data-value="new-profile"{"Add Profile"}}
            "privacy"=>{h2{"Privacy"}p class="section-description"{"Browser data stays on this Mac. Websites still make their own network requests."}(toggle("Block known ads & trackers","Bundled rules run locally.","blockTrackers",prefs["blockTrackers"].as_bool().unwrap_or(true),false))(toggle("Block unwanted popups","Requested windows can still open.","blockPopups",flag(prefs,"blockPopups"),false))div class="settings-group"{div class="list-row"{div{strong{"Browsing history"}small{"Clear saved visits for this Profile."}}button class="button" data-op="menu" data-value="clear-history"{"Clear…"}}}p class="field-help"{"Private windows do not save tabs or history. Downloads remain on disk. Private browsing does not hide activity from websites or your network."}}
            "appearance"=>{h2{"Appearance"}p class="section-description"{"Arrange tabs and panels, choose colors, and set up each Space."}button class="appearance-preview" data-op="screen" data-value="editor"{(icon("edit"))span{"Open the appearance editor"}(icon("arrow"))}}
            "ai"=>{h2{"AI providers"}p class="section-description"{"Bring a key or use a local endpoint. Secrets are saved in macOS Keychain."}(ai_form(s))}
            "passwords"=>{h2{"Passwords"}p class="section-description"{"Saved locally in macOS Keychain, separate for each Profile."}
                @for c in array(&s.snapshot["credentials"]) {div class="list-row"{(icon("key"))div{strong{(text(c,"origin"))}small{(text(c,"username"))}}div class="button-row"{button class="button" data-op="native" data-action="credentialFill" data-id=(text(c,"id")){"Fill on this page"}button class="icon-button" data-op="menu" data-value=(format!("delete-credential:{}",text(c,"id"))) aria-label="Delete saved login"{(icon("close"))}}}}
                @if !s.private(){details class="credential-disclosure"{summary{"Add a login"}form data-form="credential"{
                    label class="field"{span{"Website"}input name="origin" type="url" placeholder="https://example.com" required="";}
                    label class="field"{span{"Username"}input name="username" autocomplete="off" maxlength="500";}
                    label class="field"{span{"Password"}input name="password" type="password" autocomplete="new-password" required="";}
                    button class="button primary" type="submit"{"Save login"}
                }}}
            }
            "updates"|"engines"=>{h2{"Updates"}p class="section-description"{(text(&s.snapshot["updates"],"version"))}(toggle("Automatic updates","Update Neutrino and Chromium together after you quit. Your data stays in place.","automaticUpdates",flag(&s.snapshot["updates"],"automatic"),false))div class="settings-group"{p{(text(&s.snapshot["updates"],"message"))}div class="button-row"{button class="button primary" data-op="checkUpdates" disabled[flag(&s.snapshot["updates"],"busy")]{(if flag(&s.snapshot["updates"],"busy"){"Checking…"}else{"Check for updates"})}@if flag(&s.snapshot["updates"],"pending"){(action("Restart and install","restartUpdate",false))}@if flag(&s.snapshot["updates"],"busy"){(action("Cancel","cancelUpdate",false))}}}h2{"Website engines"}p class="section-description"{"Blink is the default. WebKit uses separate website sign-ins and does not support Chrome extensions."}div class="list-row"{(icon("globe"))div{strong{"Blink / Chromium"}small{(if flag(&s.snapshot,"blinkAvailable"){format!("Chromium {} · updates with Neutrino",text(&s.snapshot,"engineVersion"))}else{"Not present in this development build".into()})}}}div class="list-row"{(icon("globe"))div{strong{"WebKit"}small{"Provided by macOS"}}}}
            _=>{h2{"Browsing"}label class="control-label"{"Default search engine"}(segments("preference","search",text(prefs,"search"),&[("duckDuckGo","DuckDuckGo"),("google","Google"),("bing","Bing")]))(toggle("Pick up where you left off","Restore regular tabs when you reopen Neutrino.","restoreSession",flag(prefs,"restoreSession"),false))div class="list-row"{div{strong{"Default browser"}small{"Open links in Neutrino."}}(action("Set as default","defaultBrowser",false))}div class="list-row"{div{strong{"Your bookmarks"}small{"Bring over an HTML bookmarks export."}}(action("Import","importBookmarks",false))}}
        }}
    }}
}
fn empty(title: &str, detail: &str, glyph: &str) -> Markup {
    html! {div class="empty-state"{(icon(glyph))h3{(title)}p{(detail)}}}
}
fn library(s: &Shell) -> Markup {
    let section = if ["bookmarks", "history", "downloads", "notes", "archive"]
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
            @for (key,label,glyph) in [("bookmarks","Bookmarks","bookmark"),("history","History","history"),("downloads","Downloads","download"),("notes","Notes","edit"),("archive","Archived","folder")] {
                button class=(if section==key{"selected"}else{""}) data-op="section" data-value=(key) title=(label) aria-label=(label) aria-pressed=((section==key).to_string()){(icon(glyph))span{(label)}}
            }
        }
        }
        @match section {
            "history" => {
                @if array(&s.snapshot["history"]).is_empty(){(empty("A fresh start","Pages you visit in regular windows appear here.","history"))}
                @for h in array(&s.snapshot["history"]) {button class="history-row" data-op="navigate" data-value=(text(h,"url")){(site(h))span{strong{(text(h,"title"))}small{(host(text(h,"url")))}}(icon("arrow"))}}
            }
            "downloads" => {
                @if array(&s.snapshot["downloads"]).is_empty(){(empty("Nothing downloading","Files you download will appear here.","download"))}
                @for d in array(&s.snapshot["downloads"]) {div class="list-row"{(icon("download"))div{strong{(text(d,"name"))}small{(text(d,"status"))}}button class="button" data-op="native" data-action=(if flag(d,"complete"){"downloadReveal"}else{"downloadCancel"}) data-id=(text(d,"id")){(if flag(d,"complete"){"Show in Finder"}else{"Cancel"})}}}
            }
            "archive" => {
                @if array(&s.snapshot["archived"]).is_empty(){(empty("No archived tabs","Recoverable archived tabs for this Space appear here.","folder"))}
                @for t in array(&s.snapshot["archived"]) {div class="list-row"{(site(t))div{strong{(text(t,"title"))}small{(host(text(t,"url")))}}button class="button" data-op="native" data-action="restoreArchived" data-id=(text(t,"id")){"Restore"}}}
            }
            "notes" => {
                @if s.private() {(empty("Notes stay in regular windows","Private browsing does not create or change saved notes.","shield"))}
                @else {
                    button class="button" data-op="native" data-action="createNote"{(icon("plus"))"New note"}
                    div class="note-list" {@for n in array(&s.snapshot["notes"]) {button class=(if n["id"]==s.snapshot["selectedNote"]["id"]{"selected"}else{""}) data-op="native" data-action="selectNote" data-id=(text(n,"id")){(icon("edit"))span{(text(n,"title"))}}}}
                    @let n=&s.snapshot["selectedNote"];
                    @if !n.is_null() {article class="note-card"{
                        input class="note-title" value=(text(n,"title")) data-note=(text(n,"id")) data-note-field="title" maxlength="100" aria-label="Note title";
                        textarea data-note=(text(n,"id")) data-note-field="body" maxlength="200000" aria-label="Note content"{(text(n,"text"))}
                        div class="note-footer"{span{"Saved as you type"}button class="button quiet" data-op="menu" data-value=(format!("delete-note:{}",text(n,"id"))){"Delete note…"}}
                    }}
                }
            }
            _ => {
                div class="library-actions"{(action("Import","importBookmarks",false))(action("Export","exportBookmarks",false))}
                @if array(&s.snapshot["bookmarks"]).is_empty(){(empty("Your favorite places","Save a page with ⌘D, or import bookmarks from another browser.","bookmark"))}
                @for b in array(&s.snapshot["bookmarks"]) {div class="list-row"{
                    button class="bookmark-link" data-op="navigate" data-value=(text(b,"url")){(site(b))span{strong{(text(b,"title"))}small{(host(text(b,"url")))}}}
                    button class="icon-button" data-op="native" data-action="removeBookmark" data-id=(text(b,"id")) aria-label=(format!("Remove {}",text(b,"title"))){(icon("close"))}
                }}
            }
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
    html! {div class="assistant-content"{@if s.snapshot["preferences"]["ai"].is_null(){(empty("Connect your intelligence","Use an API key or a local model. You choose what to share.","spark"))button class="button primary" data-op="screen" data-value="settings" data-section="ai"{"Choose a provider"}} @else {p class="section-description"{"Ask about this page. Sending shares the page’s text with your configured provider."}div class="assistant-response"{(text(&s.snapshot,"assistantResponse"))}form data-form="assistant"{label class="field"{span{"Your question"}textarea name="prompt" placeholder="What would you like to know?" required{}}button class="button primary" type="submit" disabled[flag(&s.snapshot,"assistantBusy")]{(if flag(&s.snapshot,"assistantBusy"){"Thinking…"}else{"Share page and ask"})}}}}}
}
fn module_glyph(id: &str) -> &str {
    if id.contains("theme") {
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
        "shield"
    } else {
        "grid"
    }
}
fn module_description(module: &Value) -> &str {
    match text(module, "id") {
        "org.neutrino.reader" => "Read articles in a quiet, focused view.",
        "org.neutrino.focus" => {
            "Give the page more room. Press Escape to bring your controls back."
        }
        "org.neutrino.resource-monitor" => "See CPU and memory use while you browse.",
        "org.neutrino.memory-monitor" => "See how your Mac’s memory is being used.",
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
        div class="modules-toolbar"{div class="module-filters" role="group" aria-label="Module list"{@for (key,label) in [("installed","Installed"),("available","Available"),("all","All")]{button class=(if s.module_filter==key{"selected"}else{""}) data-op="module-filter" data-value=(key) aria-pressed=((s.module_filter==key).to_string()){(label)}}}span class="spacer"{}button class="button" data-op="importModule"{(icon("plus"))"Import"}}
        label class="module-search"{(icon("search"))input id="module-search" data-module-search="true" type="search" value=(s.module_query.as_str()) placeholder="Search modules" aria-label="Search modules" autocomplete="off";}
        @if all.is_empty(){(empty("Modules could not load","Open Recovery to repair module storage, or import a local package.","grid"))(action("Open Recovery","module-recovery",false))}
        @else if shown.is_empty(){(empty("No matching modules","Try another search or view the available modules.","search"))}
        @else {div class="module-grid"{@for m in shown{article class="module-card"{
            button class="module-open" data-op="module-select" data-value=(text(m,"id")){span class="module-icon"{(icon(module_glyph(text(m,"id"))))}div{h2{(text(m,"name"))}p{(module_description(m))}}(icon("forward"))}
            div class="module-card-footer"{span class=(if flag(m,"enabled"){"module-status active"}else{"module-status"}){(if flag(m,"enabled"){"Active"}else if flag(m,"installed"){"Disabled"}else{"Available"})}span class="spacer"{}button class="button quiet" data-op="native" data-action=(if flag(m,"installed"){"toggleModule"}else{"installModule"}) data-id=(text(m,"id")){(if !flag(m,"installed"){"Install"}else if flag(m,"enabled"){"Disable"}else if flag(m,"replacesProvider"){"Replace provider"}else{"Enable"})}}
        }}}}
        footer class="modules-footer"{span{(all.iter().filter(|m|flag(m,"enabled")).count())" active · "(all.len())" available locally"}button class="button quiet" data-op="native" data-action="importCatalog"{"Import catalog"}}
    }}
}
fn module_details(s: &Shell, m: &Value) -> Markup {
    let id = text(m, "id");
    html! {div class="module-details"{
        button class="button quiet" data-op="module-select" data-value=""{(icon("back"))"All modules"}
        header class="module-detail-heading"{span class="module-icon"{(icon(module_glyph(id)))}div{h2{(text(m,"name"))}p{(module_description(m))}}}
        div class="module-detail-actions"{button class=(if flag(m,"enabled"){"button"}else{"button primary"}) data-op="native" data-action=(if flag(m,"installed"){"toggleModule"}else{"installModule"}) data-id=(id){(if !flag(m,"installed"){"Install"}else if flag(m,"enabled"){"Disable"}else if flag(m,"replacesProvider"){"Replace provider"}else{"Enable"})}
            @if flag(m,"updateAvailable"){button class="button" data-op="native" data-action="installModule" data-id=(id){"Update to v"(m["availableVersion"].as_u64().unwrap_or(1))}}
            @if flag(m,"installed") && flag(m,"available"){button class="button" data-op="native" data-action="repairModule" data-id=(id){"Reinstall"}}
            @if flag(m,"installed"){button class="button danger" data-op="native" data-action="uninstallModule" data-id=(id){"Remove…"}}
        }
        @if flag(m,"enabled"){div class="module-use"{@match text(m,"capability"){
            "resourceMonitor"=>{button class="button primary" data-op="screen" data-value="resources"{(icon("activity"))"Open monitor"}}
            "focusMode"=>{button class="button primary" data-op="native" data-action="toggleFocus"{(icon("moon"))(if flag(&s.snapshot,"focusMode"){"Exit Focus"}else{"Enter Focus"})}}
            "notes"=>{button class="button primary" data-op="screen" data-value="library" data-section="notes"{(icon("edit"))"Open notes"}}
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

fn menu_item(label: &str, op: &str, value: &str, glyph: &str) -> Markup {
    html! {button class="menu-item" data-op=(op) data-value=(value){(icon(glyph))span{(label)}}}
}
fn menu(s: &Shell) -> Markup {
    let id = s.menu.split_once(':').map(|x| x.1).unwrap_or("");
    html! {div class=(if s.modal_menu(){"menu-scrim modal-menu"}else{"menu-scrim anchored-menu"}) data-dismiss="true"{section class="popover-menu" data-menu=(s.menu.as_str()) role="dialog" aria-modal=(s.modal_menu().to_string()) aria-label="Browser options"{header{strong{(if s.menu.starts_with("tab:"){"Tab options"}else if s.menu.starts_with("folder:"){"Folder options"}else{"Neutrino"})}(button("Close menu","escape","close"))}
        @match s.menu.as_str(){
            "browser"=>{@for item in array(&s.snapshot["menuItems"]){@match text(item,"action"){
                "newTab"=>{(menu_item(text(item,"title"),"newTab","","plus"))}
                "bookmarks"|"history"|"downloads"=>{button class="menu-item" data-op="screen" data-value="library" data-section=(text(item,"action")){(icon("bookmark"))(text(item,"title"))}}
                "modules"|"settings"|"recovery"=>{(menu_item(text(item,"title"),"screen",text(item,"action"),"grid"))}
                "customize"=>{(menu_item(text(item,"title"),"screen","editor","edit"))}
                _=>{}
            }}(menu_item("Resources","screen","resources","activity"))(menu_item("Save bookmark","bookmark","","bookmark"))(menu_item("Split view","split","","split"))(menu_item("Page assistant","screen","assistant","spark"))(menu_item("Find on page","menu","find","search"))(menu_item("New window","newWindow","","plus"))(menu_item("New private window","privateWindow","","shield"))(menu_item("Appearance","screen","editor","edit"))(menu_item("Settings","screen","settings","settings"))(menu_item("Extensions","screen","extensions","grid"))(menu_item("Modules","screen","modules","grid"))(menu_item("Reader","reader","","bookmark"))(menu_item("Capture page","capture","","download"))}
            "space"=>{(menu_item("Rename Space","menu","rename-space","edit"))(menu_item("New folder","menu","new-folder","folder"))(menu_item("New Space","menu","new-space","plus"))(menu_item("Edit this Space","screen","editor","edit"))button class="menu-item" data-op="screen" data-value="library" data-section="archive"{(icon("history"))"Archived tabs"}}
            "rename-space"=>{label class="field"{span{"Space name"}input id="name-input" data-name="true" value=(s.name.as_str()) maxlength="80";}button class="button primary" data-op="renameSpace" data-id=(text(&s.snapshot["session"],"spaceID")) disabled[s.name.is_empty()]{"Save name"}}
            "find"=>{form data-form="find"{label class="field"{span{"Find on this page"}input name="find" id="find-input" type="search" autocomplete="off";}button class="button primary" type="submit"{"Find next"}}p class="field-help"{"Matches are highlighted on the page."}}
            "new-space"|"new-folder"|"new-profile"=>{label class="field"{span{(if s.menu=="new-folder"{"Folder name"}else if s.menu=="new-profile"{"Profile name"}else{"Space name"})}input id="name-input" data-name="true" value=(s.name.as_str()) placeholder="Give it a name" maxlength="80" autocomplete="off";}button class="button primary" data-op=(if s.menu=="new-folder"{"createFolder"}else if s.menu=="new-profile"{"createProfile"}else{"createSpace"}) disabled[s.name.is_empty()]{"Create"}}
            "profiles"=>{@for p in array(&s.snapshot["profiles"]){button class="menu-item" data-op="native" data-action="switchProfile" data-id=(text(p,"id")) disabled[s.private()]{(icon("user"))(text(p,"name"))}}button class="menu-item" data-op="screen" data-value="settings" data-section="profiles"{(icon("settings"))"Manage Profiles"}}
            "clear-history"=>{p{"Clear saved history for this Profile? Your bookmarks, tabs and website sign-ins are kept."}(action("Clear history","clearHistory",true))}
            "discard-editor"=>{p{"You have unsaved appearance changes."}div class="button-row"{(action("Keep editing","escape",false))(action("Discard changes","editor-cancel",false))(action("Save changes","editor-save",true))}}
            "reset-modules"=>{p{"Stop optional modules? A local backup and your saved data are kept."}(action("Reset modules","resetModules",true))}
            _=>{@if s.menu.starts_with("delete-credential:"){p{"Delete this saved login from this Profile’s Keychain?"}button class="button primary" data-op="native" data-action="credentialDelete" data-id=(id){"Delete login"}} @else if s.menu.starts_with("delete-note:"){p{"Delete this note? This cannot be undone."}button class="button primary" data-op="native" data-action="deleteNote" data-id=(id){"Delete note"}} @else if s.menu.starts_with("tab:"){ @if let Some(t)=s.tabs().iter().find(|t|text(t,"id")==id){
                @for (op,label,glyph) in [("pinTab",if flag(t,"pinned"){"Unpin tab"}else{"Pin tab"},"pin"),("duplicateTab","Duplicate tab","plus"),("closeTab","Close tab","close")]{button class="menu-item" data-op=(op) data-id=(id){(icon(glyph))(label)}}
                div class="menu-label"{"Move to"}button class="menu-item" data-op="move-tab" data-id=(id) data-group="today"{(icon("globe"))"Today"}@for f in array(&s.snapshot["folders"]){button class="menu-item" data-op="move-tab" data-id=(id) data-group="folder" data-folder-id=(text(f,"id")){(icon("folder"))(text(f,"name"))}}
                @for space in array(&s.snapshot["spaces"]).iter().filter(|v|v["profileID"]==s.snapshot["session"]["profileID"]&&v["id"]!=s.snapshot["session"]["spaceID"]){button class="menu-item" data-op="move-space" data-id=(id) data-space-id=(text(space,"id")){(icon("sidebar"))(text(space,"name"))}}
            }} @else if s.menu.starts_with("folder:"){label class="field"{span{"Rename folder"}input data-name="true" value=(s.name.as_str()) placeholder="New name" maxlength="80"; }button class="button" data-op="renameFolder" data-id=(id) disabled[s.name.is_empty()]{"Rename"}button class="menu-item" data-op="deleteFolder" data-id=(id){(icon("close"))"Remove folder; keep its tabs"}}
            }
        }
    }}}
}
