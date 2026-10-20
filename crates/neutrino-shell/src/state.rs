// SPDX-License-Identifier: MPL-2.0
use serde_json::{json, Value};
use std::collections::HashSet;
use url::Url;

pub type Snapshot = Value;
pub fn text<'a>(value: &'a Value, key: &str) -> &'a str {
    value[key].as_str().unwrap_or("")
}
pub fn array(value: &Value) -> &[Value] {
    value.as_array().map(Vec::as_slice).unwrap_or(&[])
}
pub fn flag(value: &Value, key: &str) -> bool {
    value[key].as_bool().unwrap_or(false)
}
pub fn bound(value: &str, count: usize) -> String {
    value.trim().chars().take(count).collect()
}

#[derive(Clone)]
pub struct Shell {
    pub snapshot: Snapshot,
    pub screen: String,
    pub section: String,
    pub step: usize,
    pub setup: Value,
    pub draft: Option<Value>,
    pub undo: Vec<Value>,
    pub redo: Vec<Value>,
    pub pending_exit: Option<Value>,
    pub invalid_field: String,
    pub tab_undo: Vec<Value>,
    pub palette: bool,
    pub palette_new: bool,
    pub palette_serial: u64,
    pub palette_parent: Value,
    pub panel: String,
    pub query: String,
    pub selected_result: usize,
    pub menu: String,
    pub notice: String,
    pub name: String,
    pub sidebar_hidden: bool,
    pub edit_component: String,
    pub expanded_preview: bool,
    pub apply_space: bool,
    pub setup_busy: bool,
    pub selected_module: String,
    pub module_filter: String,
    pub module_query: String,
    pub focus: String,
    pub focus_serial: u64,
    pub address_query: String,
    pub suggest_index: usize,
    pub find_open: bool,
    pub find_query: String,
    pub find_index: usize,
    pub capture_select: bool,
    /// The area being selected goes to the markup editor instead of a file.
    pub capture_markup: bool,
    pub rail_peek: bool,
    pub recording: String,
    pub library_filter: String,
    pub board: String,
    /// The Speed Dial group shown on Vivaldi's start page; empty for the main one.
    pub dial_group: String,
    order_undo: Vec<Value>,
    adjustment: String,
}
impl Default for Shell {
    fn default() -> Self {
        Self {
            snapshot: json!({}),
            screen: "browse".into(),
            section: "general".into(),
            step: 0,
            setup: json!({"profile":"Personal","space":"Everyday","search":"duckDuckGo","blockTrackers":true,"blockAds":true,"blockPopups":true,"restoreSession":true,"appearance":"dark","accent":"purple","layout":"leading","preset":"neutrino","imported":false,"favorites":[],"sidebarTools":["messengers","history","downloads","bookmarks","control"],"edition":"classic","sounds":true}),
            draft: None,
            undo: vec![],
            redo: vec![],
            pending_exit: None,
            invalid_field: String::new(),
            tab_undo: vec![],
            palette: false,
            palette_new: false,
            palette_serial: 0,
            palette_parent: Value::Null,
            panel: String::new(),
            query: String::new(),
            selected_result: 0,
            menu: String::new(),
            notice: String::new(),
            name: String::new(),
            sidebar_hidden: false,
            edit_component: "tabs".into(),
            expanded_preview: false,
            apply_space: true,
            setup_busy: false,
            selected_module: String::new(),
            module_filter: "installed".into(),
            module_query: String::new(),
            focus: String::new(),
            focus_serial: 0,
            address_query: String::new(),
            suggest_index: 0,
            find_open: false,
            find_query: String::new(),
            find_index: 0,
            capture_select: false,
            capture_markup: false,
            rail_peek: false,
            recording: String::new(),
            library_filter: String::new(),
            board: String::new(),
            dial_group: String::new(),
            order_undo: vec![],
            adjustment: String::new(),
        }
    }
}
impl Shell {
    pub fn tabs(&self) -> &[Value] {
        array(&self.snapshot["session"]["tabs"])
    }
    pub fn active(&self) -> &Value {
        self.tabs()
            .iter()
            .find(|t| t["id"] == self.snapshot["session"]["selectedTabID"])
            .unwrap_or(&Value::Null)
    }
    pub fn config(&self) -> &Value {
        self.draft
            .as_ref()
            .filter(|_| self.screen == "editor")
            .unwrap_or(&self.snapshot["configuration"])
    }
    pub fn private(&self) -> bool {
        flag(&self.snapshot, "private")
    }
    pub fn onboarding(&self) -> bool {
        !flag(&self.snapshot, "completedOnboarding") && !flag(&self.snapshot, "smoke")
    }
    pub fn dispatch(&mut self, request: Value) -> Value {
        let op = text(&request, "op");
        if op != "sync" {
            self.focus.clear();
            self.focus_serial = self.focus_serial.wrapping_add(1);
        }
        if !["sync", "editor-value"].contains(&op) {
            self.adjustment.clear();
        }
        // Every route out of editing shares the same save/discard boundary.
        if self.screen == "editor"
            && !["sync", "escape", "menu", "dock"].contains(&op)
            && !op.starts_with("editor-")
            && op != "name"
        {
            if self.draft.as_ref() != Some(&self.snapshot["configuration"]) {
                self.pending_exit = Some(request);
                self.menu = "discard-editor".into();
                return self.response(vec![]);
            }
            self.close_screen();
        }
        if flag(&self.snapshot, "downloadsWindow")
            && op != "sync"
            && op != "escape"
            && !(op == "native"
                && ["downloadCancel", "downloadPause", "downloadResume", "downloadReveal", "downloadOpen"]
                    .contains(&text(&request, "action")))
        {
            return self.response(vec![]);
        }
        let mut commands: Vec<Value> = vec![];
        if op != "sync" {
            self.notice.clear();
        }
        if op == "sync" {
            let previous = self.snapshot["session"]["spaceID"].clone();
            self.snapshot = request["snapshot"].clone();
            if flag(&self.snapshot, "downloadsWindow") {
                self.screen = "library".into();
                self.section = "downloads".into();
            }
            if previous != self.snapshot["session"]["spaceID"] {
                self.tab_undo.clear();
                self.order_undo.clear();
                self.menu.clear();
                self.palette = false;
            }
            if self.setup_busy && !flag(&self.snapshot, "saving") {
                self.setup_busy = false;
            }
        } else if flag(&self.snapshot, "frozen") {
            self.notice = "Neutrino is saving before closing.".into();
        } else {
            match op {
                "noop" => {}
                "dismiss-notice" => {
                    self.notice.clear();
                    commands.push(json!({"op":"clearNotice"}));
                }
                "transient-dismiss" => self.notice.clear(),
                "focus-address" => {
                    self.sidebar_hidden = false;
                    self.focus = "address-input".into();
                    if flag(&self.snapshot, "focusMode") {
                        commands.push(json!({"op":"exitFocus"}));
                    }
                }
                "palette" => {
                    self.palette_serial = self.palette_serial.wrapping_add(1);
                    self.palette = true;
                    self.focus = "command-input".into();
                    self.palette_new = false;
                    self.palette_parent = Value::Null;
                    self.menu.clear();
                    self.query = text(&request, "value").into();
                    self.selected_result = 0;
                }
                "query" => {
                    self.query = bound(text(&request, "value"), 8192);
                    self.selected_result = 0;
                    if !self.query.is_empty() {
                        commands.push(json!({"op":"suggest","value":bound(&self.query, 2048)}));
                    }
                }
                "result-next" => {
                    self.selected_result =
                        (self.selected_result + 1).min(self.results().len().saturating_sub(1));
                }
                "result-previous" => {
                    self.selected_result = self.selected_result.saturating_sub(1);
                }
                "escape" => {
                    if self.capture_select || self.rail_peek || !self.recording.is_empty() {
                        self.capture_select = false;
                        self.rail_peek = false;
                        self.recording.clear();
                    } else if self.palette {
                        self.palette = false;
                    } else if !self.menu.is_empty() {
                        if self.menu == "suggest" {
                            self.address_query.clear();
                        }
                        if self.menu == "discard-editor" {
                            self.pending_exit = None;
                        }
                        if self.menu == "notes-scope" && flag(&request, "restoreFocus") {
                            self.focus = "notes-scope-trigger".into();
                        }
                        self.menu.clear();
                    } else if self.screen == "editor"
                        && self.draft.as_ref() != Some(&self.snapshot["configuration"])
                    {
                        self.menu = "discard-editor".into();
                    } else if flag(&self.snapshot, "focusMode") {
                        commands.push(json!({"op":"exitFocus"}));
                        self.close_screen();
                    } else {
                        self.close_screen();
                    }
                }
                "screen" => {
                    let screen = text(&request, "value");
                    if screen == "modules" {
                        self.selected_module.clear();
                    }
                    if [
                        "browse",
                        "settings",
                        "editor",
                        "library",
                        "modules",
                        "extensions",
                        "assistant",
                        "reader",
                        "resources",
                        "recovery",
                        "source",
                        "overview",
                    ]
                    .contains(&screen)
                    {
                        self.screen = screen.into();
                        self.menu.clear();
                        self.palette = false;
                        if screen == "editor" {
                            self.draft = Some(self.snapshot["configuration"].clone());
                            self.undo.clear();
                            self.redo.clear();
                            self.apply_space = true;
                        }
                        if let Some(section) = request["section"].as_str() {
                            self.section = section.into();
                        }
                        if screen == "settings"
                            && ![
                                "general",
                                "profiles",
                                "privacy",
                                "appearance",
                                "ai",
                                "passwords",
                                "updates",
                                "engines",
                                "performance",
                                "shortcuts",
                                "autofill",
                                "search",
                            ]
                            .contains(&self.section.as_str())
                        {
                            self.section = "general".into();
                        }
                        if screen == "library" {
                            self.library_filter.clear();
                            if !["bookmarks", "history", "downloads", "notes", "archive", "reading", "sessions", "boards"]
                                .contains(&self.section.as_str())
                            {
                                self.section = "bookmarks".into();
                            }
                            commands.push(json!({"op":"projectLibrary","section":self.section}));
                        }
                    }
                }
                "section" => {
                    self.section = bound(text(&request, "value"), 40);
                    self.library_filter.clear();
                    if self.screen == "browse"
                        && ["bookmarks", "history", "downloads", "notes", "archive"]
                            .contains(&self.section.as_str())
                    {
                        self.panel = self.section.clone();
                        commands.push(json!({"op":"projectLibrary","section":self.section}));
                    }
                    if self.screen == "library" {
                        commands.push(json!({"op":"projectLibrary","section":self.section}));
                    }
                }
                "menu" => {
                    self.menu = bound(text(&request, "value"), 9000);
                    self.name.clear();
                }
                "name" => {
                    self.name = bound(text(&request, "value"), 80);
                }
                "sidebar" => {
                    self.sidebar_hidden = !self.sidebar_hidden;
                }
                "reveal-workspace" => {
                    self.close_screen();
                    self.panel = "closed".into();
                    self.sidebar_hidden = false;
                }
                "navigate" | "activate-result" => {
                    let value = if op == "activate-result" {
                        self.results()
                            .get(self.selected_result)
                            .cloned()
                            .unwrap_or(json!({"kind":"search","value":self.query}))
                    } else {
                        json!({"kind":"search","value":text(&request,"value")})
                    };
                    if text(&value, "kind") == "tab" {
                        commands.push(json!({"op":"selectTab","id":value["id"]}));
                        self.palette = false;
                        self.close_screen();
                    } else if text(&value, "kind") == "command" {
                        self.palette = false;
                        return self.dispatch(json!({"op":"screen","value":value["value"]}));
                    } else if text(&value, "kind") == "action" {
                        return self.dispatch(json!({"op":"run-action","value":value["value"]}));
                    } else if let Some(url) = crate::features::resolve(self, text(&value, "value")) {
                        self.address_query.clear();
                        if self.menu == "suggest" {
                            self.menu.clear();
                        }
                        if op == "activate-result" && self.palette_new {
                            commands.push(
                                json!({"op":"newTab","url":url,"parentID":self.palette_parent}),
                            );
                        } else {
                            commands.push(json!({"op":"navigate","url":url}));
                        }
                        self.palette = false;
                        self.close_screen();
                    } else {
                        self.notice = "Enter a website address or a search.".into();
                    }
                }
                "select-result" => {
                    self.selected_result = request["index"].as_u64().unwrap_or(0) as usize;
                    return self.dispatch(json!({"op":"activate-result"}));
                }
                // Chrome, Safari, Brave, Opera GX and Vivaldi add a tab showing their start
                // page with the address field focused; Arc and Neutrino ask in the command bar.
                "newTab" if crate::render::opens_blank_tab(self) => {
                    let parent = self.tabs().iter().find(|t| t["id"] == request["parentID"]).map(|t| t["id"].clone()).unwrap_or(Value::Null);
                    commands.push(json!({"op":"newTab","parentID":parent}));
                    self.palette = false;
                    self.menu.clear();
                    self.close_screen();
                    self.sidebar_hidden = false;
                    self.focus = "address-input".into();
                }
                "newTab" => {
                    self.palette_serial = self.palette_serial.wrapping_add(1);
                    self.palette = true;
                    self.focus = "command-input".into();
                    self.palette_new = true;
                    self.palette_parent = self
                        .tabs()
                        .iter()
                        .find(|t| t["id"] == request["parentID"])
                        .map(|t| t["id"].clone())
                        .unwrap_or(Value::Null);
                    self.query.clear();
                    self.selected_result = 0;
                    self.menu.clear();
                }
                "closeCurrent" => {
                    if self.palette {
                        self.palette = false;
                    } else {
                        commands.push(
                            json!({"op":"closeTab","id":self.snapshot["session"]["selectedTabID"]}),
                        );
                    }
                }
                "panel" | "open-panel" => {
                    let value = text(&request, "value");
                    let web = value.strip_prefix("web:").is_some_and(|id| {
                        array(&self.snapshot["preferences"]["webPanels"]).iter().any(|p| text(p, "id") == id)
                    });
                    if web || [
                        "",
                        "bookmarks",
                        "history",
                        "downloads",
                        "notes",
                        "resources",
                        "tabs",
                        "safari",
                        "feeds",
                        "reading",
                    ]
                    .contains(&value)
                    {
                        self.panel =
                            if value.is_empty() || (op == "panel" && self.panel_key() == value) {
                                "closed".into()
                            } else {
                                value.into()
                            };
                        if self.panel == "feeds" {
                        } else if self.panel == "safari" {
                            commands.push(json!({"op":"projectLibrary","section":"bookmarks"}));
                        } else if !["resources", "tabs", "closed"].contains(&self.panel.as_str()) && !self.panel.starts_with("web:") {
                            self.section = self.panel.clone();
                            commands.push(json!({"op":"projectLibrary","section":self.panel}));
                        }
                        self.screen = "browse".into();
                    }
                }
                "panel-toggle" => {
                    self.panel = if self.panel_key().is_empty() { "bookmarks".into() } else { "closed".into() };
                    if self.panel == "bookmarks" {
                        self.section = "bookmarks".into();
                        commands.push(json!({"op":"projectLibrary","section":"bookmarks"}));
                    }
                    self.screen = "browse".into();
                }
                "zoom-step" => {
                    let current = self.snapshot["zoom"].as_f64().unwrap_or(1.);
                    let step: f64 = text(&request, "value").parse().unwrap_or(0.);
                    let next = if step == 0. { 1. } else { ((current + step * 0.1) * 10.).round() / 10. };
                    if !text(self.active(), "url").is_empty() {
                        commands.push(json!({"op":"setZoom","value":next.clamp(0.5, 3.)}));
                    }
                }
                "zoom-set" => {
                    let percent = request["value"].as_f64().or_else(|| text(&request, "value").parse().ok()).unwrap_or(100.);
                    if !text(self.active(), "url").is_empty() && percent.is_finite() {
                        commands.push(json!({"op":"setZoom","value":(percent / 100.).clamp(0.5, 3.)}));
                    }
                }
                "addSite" => {
                    let input = self.name.trim();
                    let candidate = if input.contains("://") { input.to_string() } else { format!("https://{input}") };
                    if let Ok(url) = Url::parse(&candidate) {
                        if ["http", "https"].contains(&url.scheme()) && url.host_str().is_some_and(|h| h.contains('.')) && !self.private() {
                            let title = url.host_str().unwrap_or("").trim_start_matches("www.").to_string();
                            commands.push(json!({"op":"addBookmark","url":url.as_str(),"title":title,"folder":if self.menu == "add-site:dial" {crate::views::dial_folder(self)} else {String::new()}}));
                            self.menu.clear();
                            self.name.clear();
                        } else {
                            self.notice = "Enter a website address, like example.com.".into();
                        }
                    }
                }
                "home" => {
                    commands.push(json!({"op":"home"}));
                    self.screen = "browse".into();
                }
                "shields-restore" => {
                    let site = text(&request, "value");
                    if array(&self.snapshot["preferences"]["shieldsDown"]).iter().any(|h| h.as_str() == Some(site)) {
                        commands.push(json!({"op":"shieldsSite","host":site,"down":false}));
                    }
                }
                "shields-site" => {
                    let site = crate::render::host(text(self.active(), "url"));
                    if !text(self.active(), "url").is_empty() && !self.private() {
                        let down = array(&self.snapshot["preferences"]["shieldsDown"]).iter().any(|h| h.as_str() == Some(site.as_str()));
                        commands.push(json!({"op":"shieldsSite","host":site,"down":!down}));
                        self.menu.clear();
                    }
                }
                "setup-preset" => {
                    if let Some(c) = crate::appearance::preset(text(&request, "value")) {
                        self.setup["preset"] = request["value"].clone();
                        self.setup["appearance"] = c["theme"]["colorMode"].clone();
                        self.setup["accent"] = c["theme"]["accent"].clone();
                        self.setup["accentHex"] = c["theme"]["accentHex"].clone();
                        self.setup["layout"] = c["layout"]["tabs"].clone();
                    }
                }
                "setup-module" => {
                    let id = text(&request, "value");
                    if let Some(m) = array(&self.snapshot["modules"]).iter().find(|m| text(m, "id") == id && flag(m, "bundled")) {
                        let on = crate::onboarding::module_on(self, m);
                        self.setup["modules"][id] = json!(!on);
                    }
                }
                "setup-modules" => match text(&request, "value") {
                    "defaults" => {
                        self.setup["modules"] = json!({});
                        self.setup["providers"] = json!({});
                    }
                    "all" => {
                        let ids: Vec<String> = array(&self.snapshot["modules"]).iter().filter(|m| flag(m, "bundled") && text(m, "capability") == "feature").map(|m| text(m, "id").to_string()).collect();
                        for id in ids {
                            self.setup["modules"][id.as_str()] = json!(true);
                        }
                    }
                    _ => {}
                },
                "setup-provider" => {
                    let (role, id) = (text(&request, "key"), text(&request, "value"));
                    let known = array(&self.snapshot["modules"]).iter().any(|m| flag(m, "bundled") && text(m, "capability") == role && text(m, "id") == id);
                    if ["tabSystem", "resourceMonitor", "theme", "icons", "layout"].contains(&role) && (known || (id.is_empty() && role != "tabSystem")) {
                        self.setup["providers"][role] = json!(id);
                    }
                }
                "setup-favorite" | "setup-tool" => {
                    let value = text(&request, "value");
                    let (key, allowed) = if op == "setup-favorite" {
                        ("favorites", crate::appearance::FAVORITE_SITES.iter().any(|site| site.1 == value))
                    } else {
                        ("sidebarTools", crate::appearance::SIDEBAR_TOOLS.iter().any(|tool| tool.0 == value))
                    };
                    if allowed {
                        let mut list: Vec<Value> = array(&self.setup[key]).to_vec();
                        if let Some(index) = list.iter().position(|v| v == value) {
                            list.remove(index);
                        } else if list.len() < 12 {
                            list.push(json!(value));
                        }
                        self.setup[key] = json!(list);
                    }
                }
                "editor-preset" => {
                    if self.draft.is_some() {
                        if let Some(c) = crate::appearance::preset(text(&request, "value")) {
                            self.push_undo();
                            self.draft = Some(c);
                        }
                    }
                }
                "split-with" => {
                    let id = &request["id"];
                    let panes = crate::render::split_panes(&self.snapshot["session"]["split"]);
                    if *id != self.active()["id"]
                        && !panes.contains(&id.as_str().unwrap_or(""))
                        && panes.len() < crate::render::MAX_SPLIT_PANES
                        && self
                            .tabs()
                            .iter()
                            .any(|t| t["id"] == *id && !text(t, "url").is_empty())
                    {
                        commands.push(json!({"op":"splitWith","id":id}));
                        self.menu.clear();
                    }
                }
                "split-remove" => {
                    let panes = crate::render::split_panes(&self.snapshot["session"]["split"]);
                    if let Some(id) = request["id"].as_str().filter(|id| panes.contains(id)) {
                        commands.push(json!({"op":"splitRemove","id":id}));
                    }
                }
                "selectTab" | "closeTab" | "duplicateTab" | "pinTab" | "toggleBranch" => {
                    if let Some(tab) = self
                        .tabs()
                        .iter()
                        .find(|t| t["id"] == request["id"])
                        .cloned()
                    {
                        commands.push(json!({"op":op,"id":tab["id"]}));
                        self.menu.clear();
                        if ["selectTab", "closeTab"].contains(&op) {
                            self.palette = false;
                        }
                    }
                }
                "switchSpace" => {
                    if !self.private()
                        && array(&self.snapshot["spaces"]).iter().any(|s| {
                            s["id"] == request["id"]
                                && s["profileID"] == self.snapshot["session"]["profileID"]
                        })
                    {
                        commands.push(json!({"op":op,"id":request["id"]}));
                        self.menu.clear();
                        self.screen = "browse".into();
                    }
                }
                "chrome-page" | "chrome-page-close" => {
                    if self.tabs().iter().any(|t| t["id"] == request["id"])
                        && array(&self.snapshot["chromePages"][text(&request, "id")])
                            .iter()
                            .any(|p| p["id"] == request["page"])
                    {
                        commands.push(json!({"op":if op=="chrome-page"{"selectChromePage"}else{"closeChromePage"},"id":request["id"],"page":request["page"]}));
                        self.close_screen();
                    }
                }
                "move-tab" => self.move_tab(&request, &mut commands),
                "space-step" => {
                    if !self.private() {
                        let spaces: Vec<_> = array(&self.snapshot["spaces"])
                            .iter()
                            .filter(|v| v["profileID"] == self.snapshot["session"]["profileID"])
                            .collect();
                        if let Some(i) = spaces
                            .iter()
                            .position(|s| s["id"] == self.snapshot["session"]["spaceID"])
                        {
                            let step = request["value"].as_i64().unwrap_or(0).signum();
                            let next = (i as i64 + step)
                                .clamp(0, spaces.len().saturating_sub(1) as i64)
                                as usize;
                            if next != i {
                                commands.push(json!({"op":"switchSpace","id":spaces[next]["id"]}));
                                self.screen = "browse".into();
                                self.menu.clear();
                                self.palette = false;
                            }
                        }
                    }
                }
                "reorder-spaces" | "reorder-folders" => self.reorder(&request, &mut commands),
                "undo-tabs" => {
                    if let Some(change) = self.order_undo.pop() {
                        let key = if change["op"] == "reorderSpaces" {
                            "spaces"
                        } else {
                            "folders"
                        };
                        let current: HashSet<_> = array(&self.snapshot[key])
                            .iter()
                            .filter(|v| {
                                key != "spaces"
                                    || v["profileID"] == self.snapshot["session"]["profileID"]
                            })
                            .map(|v| text(v, "id"))
                            .collect();
                        let previous: HashSet<_> = array(&change["ids"])
                            .iter()
                            .filter_map(Value::as_str)
                            .collect();
                        if current == previous {
                            commands.push(change);
                            self.notice = "Order restored.".into();
                        } else {
                            self.notice =
                                "The list changed; that move can no longer be undone.".into();
                        }
                        return self.response(commands);
                    }
                    if let Some(entry) = self.tab_undo.pop() {
                        // A stack's entry also lists the folders that existed before it.
                        let tabs = if entry.is_object() { entry["tabs"].clone() } else { entry.clone() };
                        let current: HashSet<_> =
                            self.tabs().iter().map(|t| text(t, "id")).collect();
                        let prior: HashSet<_> =
                            array(&tabs).iter().map(|t| text(t, "id")).collect();
                        if current == prior {
                            commands.push(json!({"op":"replaceTabs","tabs":tabs}));
                            if entry.is_object() {
                                for folder in array(&self.snapshot["folders"]) {
                                    let added = !array(&entry["folders"]).contains(&folder["id"]);
                                    if added && !array(&tabs).iter().any(|t| t["folderID"] == folder["id"]) {
                                        commands.push(json!({"op":"deleteFolder","id":folder["id"]}));
                                    }
                                }
                            }
                            self.notice = "Tab move undone.".into();
                        } else {
                            self.notice =
                                "Tabs changed since that move; undo is no longer available.".into();
                        }
                    }
                }
                "createFolder" | "createSpace" | "createProfile" | "renameFolder"
                | "renameSpace" => {
                    if !self.name.is_empty() && !self.private() {
                        commands.push(json!({"op":op,"name":self.name,"id":request["id"]}));
                        self.menu.clear();
                        self.name.clear();
                    }
                }
                "toggleFolder" | "deleteFolder" => {
                    if array(&self.snapshot["folders"])
                        .iter()
                        .any(|f| f["id"] == request["id"])
                    {
                        commands.push(json!({"op":op,"id":request["id"]}));
                        self.menu.clear();
                    }
                }
                // A tab dropped here from another window joins this window's Space.
                "adopt-tab" => {
                    let id = text(&request, "id");
                    if !self.private() && id.len() == 36 && id.chars().all(|c| c.is_ascii_hexdigit() || c == '-') {
                        commands.push(json!({"op":"adoptTab","id":id}));
                    }
                }
                "move-space" => {
                    if !self.private() && self.tabs().iter().any(|t| t["id"] == request["id"]) {
                        if let Some(space) = array(&self.snapshot["spaces"]).iter().find(|s| {
                            s["id"] == request["spaceID"]
                                && s["profileID"] == self.snapshot["session"]["profileID"]
                                && s["id"] != self.snapshot["session"]["spaceID"]
                        }) {
                            commands.push(json!({"op":"moveTabToSpace","id":request["id"],"spaceID":space["id"]}));
                            self.menu.clear();
                        } else {
                            self.notice="Move tabs between Spaces using the same Profile. Duplicate into another Profile to keep its sign-ins separate.".into();
                        }
                    }
                }
                "setup-field" => {
                    let key = text(&request, "key");
                    if [
                        "profile",
                        "space",
                        "search",
                        "appearance",
                        "accent",
                        "layout",
                    ]
                    .contains(&key)
                    {
                        self.setup[key] = json!(bound(text(&request, "value"), 80));
                        if self.invalid_field == key {
                            self.invalid_field.clear();
                        }
                    } else if key == "accentHex" && crate::appearance::hex(text(&request, "value")) {
                        self.setup[key] = json!(text(&request, "value").trim_start_matches('#'));
                    } else if key == "edition" && ["essentials", "classic", "full"].contains(&text(&request, "value")) {
                        self.setup[key] = request["value"].clone();
                    } else if key == "theme" {
                        if let Some(t) = crate::appearance::VIVALDI_THEMES.iter().find(|t| t.0 == text(&request, "value")) {
                            self.setup["theme"] = json!(t.0);
                            self.setup["appearance"] = json!(t.2);
                            self.setup["accentHex"] = json!(t.3);
                        }
                    } else if ["blockTrackers", "blockAds", "blockPopups", "restoreSession", "sounds"].contains(&key) {
                        if let Some(v) = request["value"].as_bool() {
                            self.setup[key] = json!(v);
                        }
                    }
                }
                "setup-next" => {
                    let flow = crate::appearance::setup_flow(text(&self.setup, "preset"));
                    if flow.get(self.step) == Some(&"workspace")
                        && (text(&self.setup, "profile").is_empty()
                            || text(&self.setup, "space").is_empty())
                    {
                        self.invalid_field = if text(&self.setup, "profile").is_empty() {
                            "profile"
                        } else {
                            "space"
                        }
                        .into();
                    } else {
                        self.step = (self.step + 1).min(flow.len() - 1);
                    }
                }
                "setup-back" => {
                    self.step = self.step.saturating_sub(1);
                }
                "setup-step" => {
                    let last = crate::appearance::setup_flow(text(&self.setup, "preset")).len() - 1;
                    self.step = (request["value"].as_u64().unwrap_or(0) as usize).min(last);
                }
                "setup-finish" => {
                    let last = crate::appearance::setup_flow(text(&self.setup, "preset")).len() - 1;
                    if self.step == last
                        && !self.setup_busy
                        && !text(&self.setup, "profile").is_empty()
                        && !text(&self.setup, "space").is_empty()
                    {
                        let mut setup = self.setup.clone();
                        setup["modules"] = crate::onboarding::module_choices(self);
                        setup["webPanels"] = json!(crate::appearance::setup_web_panels(&self.setup).iter().map(|(title, url)| json!({"title":title,"url":url})).collect::<Vec<_>>());
                        setup["filterLists"] = json!(crate::appearance::setup_filter_lists(&self.setup).iter().filter_map(|id| crate::features::FILTER_LISTS.iter().find(|l| l.0 == *id)).map(|(id, title, url, _)| json!({"id":id,"title":title,"url":url})).collect::<Vec<_>>());
                        commands.push(json!({"op":"finishSetup","setup":setup,"configuration":crate::appearance::setup_configuration(&self.setup)}));
                        self.setup_busy = true;
                    }
                }
                "importBookmarks" | "defaultBrowser" => {
                    commands.push(json!({"op":op}));
                }
                "importBrowser" => {
                    let source = text(&request, "value");
                    if crate::onboarding::IMPORT_SOURCES.iter().any(|(id, _)| *id == source) {
                        commands.push(json!({"op":"importBrowser","value":source}));
                    }
                }
                "setup-blocking" => {
                    let level = text(&request, "value");
                    if ["none", "trackers", "ads"].contains(&level) {
                        self.setup["blockTrackers"] = json!(level != "none");
                        self.setup["blockAds"] = json!(level == "ads");
                    }
                }
                "editor-select" => {
                    if ["tabs", "navigation", "bookmarks", "panels"]
                        .contains(&text(&request, "value"))
                    {
                        self.edit_component = text(&request, "value").into();
                    }
                }
                "editor-scope" => {
                    self.apply_space = request["value"].as_bool().unwrap_or(true);
                }
                "editor-value" => self.edit_value(&request),
                "editor-save-named" => {
                    if let Some(config) = &self.draft {
                        if !self.name.is_empty() {
                            commands.push(json!({"op":"saveNamedSetup","name":self.name,"configuration":config,"requirements":config["requiredModuleIDs"]}));
                        }
                    }
                }
                "editor-replace-named" => {
                    if let Some(config) = &self.draft {
                        commands.push(json!({"op":"replaceNamedSetup","id":request["id"],"configuration":config,"requirements":config["requiredModuleIDs"]}));
                    }
                }
                "editor-rename-named" => {
                    commands.push(json!({"op":"renameNamedSetup","id":request["id"],"name":text(&request,"value")}));
                }
                "editor-delete-named" => {
                    self.menu = format!("delete-setup:{}", text(&request, "id"));
                }
                "editor-remove-named" => {
                    commands.push(json!({"op":"deleteNamedSetup","id":request["id"]}));
                    self.menu.clear();
                }
                "editor-load-named" => {
                    if let Some(c) = array(&self.snapshot["savedConfigurations"])
                        .iter()
                        .find(|c| c["id"] == request["id"])
                    {
                        let mut config = c["configuration"].clone();
                        config["requiredModuleIDs"] = c["requiredModuleIDs"].clone();
                        self.push_undo();
                        self.draft = Some(config);
                    }
                }
                "editor-preview-size" => self.expanded_preview = !self.expanded_preview,
                "editor-end-adjustment" => {}
                "dock" => self.dock(&request),
                "editor-undo" => {
                    if let Some(value) = self.undo.pop() {
                        if let Some(current) = self.draft.replace(value) {
                            self.redo.push(current);
                        }
                    }
                }
                "editor-redo" => {
                    if let Some(value) = self.redo.pop() {
                        if let Some(current) = self.draft.replace(value) {
                            self.undo.push(current);
                        }
                    }
                }
                "editor-reset" => {
                    self.push_undo();
                    self.draft = Some(default_configuration());
                }
                "editor-cancel" => {
                    let pending = self.pending_exit.take();
                    self.close_screen();
                    if let Some(pending) = pending {
                        return self.dispatch(pending);
                    }
                }
                "editor-save" => {
                    if let Some(config) = &self.draft {
                        commands.push(json!({"op":"applyConfiguration","requirements":config["requiredModuleIDs"],"configuration":config,"space":self.apply_space}));
                    }
                }
                "editor-result" => {
                    self.notice = bound(text(&request, "message"), 1000);
                    if flag(&request, "success") {
                        if text(&request, "action") == "saveNamedSetup" {
                            self.name.clear();
                        }
                        if text(&request, "action") == "applyConfiguration" {
                            let pending = self.pending_exit.take();
                            self.panel.clear();
                            self.close_screen();
                            if let Some(pending) = pending {
                                let next = self.dispatch(pending);
                                commands.extend(array(&next["commands"]).iter().cloned());
                            }
                            self.notice = "Appearance saved.".into();
                        }
                    }
                }
                "sidebar-width" => {
                    let width = request["value"].as_f64().unwrap_or(240.).clamp(200., 340.);
                    commands.push(json!({"op":"sidebarWidth","value":width}));
                }
                "preference" => {
                    let key = text(&request, "key");
                    let value = &request["value"];
                    if [
                        "blockTrackers",
                        "blockPopups",
                        "restoreSession",
                        "automaticUpdates",
                        "startGuideHidden",
                        "blockAds",
                    ]
                    .contains(&key)
                        && value.is_boolean()
                    {
                        commands.push(json!({"op":op,"key":key,"value":value}));
                    }
                    if key == "search"
                        && ["duckDuckGo", "google", "bing"].contains(&value.as_str().unwrap_or(""))
                    {
                        commands.push(json!({"op":op,"key":key,"value":value}));
                        commands.push(json!({"op":op,"key":"defaultSearchID","value":""}));
                    }
                }
                "back" | "forward" | "reload" | "stop" | "bookmark" | "reopenTab" | "split"
                | "unsplit" | "checkUpdates" | "downloadUpdate" | "importInstaller"
                | "discardUpdate" | "restartUpdate" | "cancelUpdate" | "newWindow"
                | "privateWindow" | "importModule" | "installExtension" | "webStore" | "reader"
                | "capture" | "exportBookmarks" | "clearHistory" | "signIn" | "disconnectAI"
                | "disableAI" | "cancelAI" | "restoreLayout" | "resetModules" | "retrySave"
                | "showDataFolder" | "uninstall" => {
                    commands.push(json!({"op":op}));
                    self.menu.clear();
                }
                "find" => {
                    commands.push(json!({"op":"find","value":bound(text(&request,"value"),1024),"backwards":flag(&request,"backwards")}));
                }
                "saveCredential" => {
                    let origin = text(&request, "origin");
                    let username = text(&request, "username");
                    let password = text(&request, "password");
                    if !self.private()
                        && resolve_address(origin, "")
                            .is_some_and(|v| v.starts_with("https://") || v.starts_with("http://"))
                        && origin.contains("://")
                        && username.chars().count() <= 500
                        && !username.contains('\n')
                        && !password.is_empty()
                        && password.len() <= 8192
                    {
                        commands.push(json!({"op":"saveCredential","origin":origin,"username":username,"password":password}));
                    } else {
                        self.notice = "Enter a website URL, username and password.".into();
                    }
                }
                "saveAI" => {
                    // Keys pass directly to Keychain; never retain them in shell state or HTML.
                    let p = text(&request, "provider");
                    let endpoint = text(&request, "endpoint");
                    let model = bound(text(&request, "model"), 200);
                    if validate_ai(p, endpoint, &model) && text(&request, "key").len() <= 8192 {
                        commands.push(json!({"op":"saveAI","provider":p,"endpoint":endpoint,"model":model,"key":text(&request,"key"),"useAccount":flag(&request,"useAccount")}));
                    } else {
                        self.notice="Enter a model and a supported HTTPS endpoint, or a local endpoint on localhost.".into();
                    }
                }
                "assistant" => {
                    let prompt = bound(text(&request, "value"), 8192);
                    if !prompt.is_empty() {
                        commands.push(json!({"op":"assistant","value":prompt,"selection":flag(&request,"selection")}));
                    }
                }
                "assistant-clear" => {
                    if !flag(&self.snapshot, "assistantBusy") {
                        commands.push(json!({"op":"assistantClear"}));
                    }
                }
                "native" => {
                    // Finite allowlist for identifier-based platform services, never an arbitrary selector.
                    let action = text(&request, "action");
                    if [
                        "downloadCancel",
                        "downloadPause",
                        "downloadResume",
                        "downloadReveal",
                        "downloadOpen",
                        "removeBookmark",
                        "restoreArchived",
                        "toggleModule",
                        "installModule",
                        "repairModule",
                        "uninstallModule",
                        "importCatalog",
                        "removeCatalog",
                        "removeExtension",
                        "extensionAction",
                        "openExtensionOptions",
                        "switchProfile",
                        "credentialFill",
                        "credentialDelete",
                        "saveNote",
                        "deleteNote",
                        "createNote",
                        "selectNote",
                        "notesScope",
                        "notesQuery",
                        "openNoteSource",
                        "noteFromPage",
                        "quoteSelection",
                        "libraryPage",
                        "useWebKit",
                        "reloadTab",
                        "toggleFocus",
                        "retryResources",
                        "historyQuery",
                        "bookmarkQuery",
                        "removeHistory",
                        "downloadRemove",
                        "downloadClear",
                        "chooseWallpaper",
                        "removeWallpaper",
                        "chooseDownloadFolder",
                        "clearDownloadFolder",
                        "importPasswords",
                        "exportPasswords",
                    ]
                    .contains(&action)
                        && !(self.private()
                            && [
                                "saveNote",
                                "deleteNote",
                                "createNote",
                                "noteFromPage",
                                "quoteSelection",
                                "openNoteSource",
                                "credentialDelete",
                                "chooseWallpaper",
                                "importPasswords",
                                "exportPasswords",
                            ]
                            .contains(&action))
                    {
                        if action == "openNoteSource" {
                            self.close_screen();
                        }
                        commands
                            .push(json!({"op":action,"id":request["id"],"value":request["value"]}));
                        if action == "toggleFocus" {
                            self.screen = "browse".into();
                            self.menu.clear();
                        }
                        if action == "notesScope" {
                            self.menu.clear();
                            self.focus = "notes-scope-trigger".into();
                        }
                        if action == "deleteNote" || action == "credentialDelete" {
                            self.menu.clear();
                        }
                    }
                }
                "module-select" => {
                    let id = text(&request, "value");
                    if id.is_empty()
                        || array(&self.snapshot["modules"])
                            .iter()
                            .any(|m| text(m, "id") == id)
                    {
                        self.selected_module = id.into();
                    }
                }
                "module-filter" => {
                    let value = text(&request, "value");
                    if ["installed", "available", "all"].contains(&value) {
                        self.module_filter = value.into();
                    }
                }
                "module-query" => self.module_query = bound(text(&request, "value"), 200),
                "module-recovery" => self.screen = "recovery".into(),
                "module-setting" => {
                    let id = text(&request, "id");
                    let key = text(&request, "key");
                    if array(&self.snapshot["modules"]).iter().any(|m| {
                        text(m, "id") == id
                            && flag(m, "installed")
                            && array(&m["settings"]).iter().any(|s| text(s, "id") == key)
                    }) {
                        commands.push(json!({"op":"setModuleSetting","id":id,"key":key,"value":request["value"]}));
                    }
                }
                "summarize" => {
                    if !text(self.active(), "url").is_empty() {
                        self.screen = "assistant".into();
                        self.menu.clear();
                        if !self.snapshot["preferences"]["ai"].is_null() {
                            commands.push(json!({"op":"assistant","value":"Summarize this page in five short bullet points.","selection":false}));
                        }
                    }
                }
                _ if crate::features::OPS.contains(&op) => {
                    crate::features::dispatch(self, op, &request, &mut commands)
                }
                _ => {
                    self.notice = "That action is unavailable.".into();
                }
            }
        }
        self.response(commands)
    }
    fn response(&self, commands: Vec<Value>) -> Value {
        json!({"html":crate::render::render(self).into_string(),"commands":commands,"editing":self.screen=="editor","screen":self.screen,"moduleSettingsID":if self.screen=="modules"{self.selected_module.as_str()}else{""},"librarySection":if self.screen=="library"{self.section.as_str()}else{self.visible_panel_key()},"commandRevision":self.palette_serial,"resourcesVisible":self.screen=="resources" || self.visible_panel_key()=="resources","context":format!("{}:{}",text(&self.snapshot["session"],"profileID"),text(&self.snapshot["session"],"spaceID")),"announce":self.notice,"undoAvailable":!self.order_undo.is_empty()||!self.tab_undo.is_empty(),"overlay":self.onboarding() || self.palette || !["browse","editor"].contains(&self.screen.as_str()) || self.modal_menu() || self.capture_select || flag(&self.snapshot,"breakMode") || text(&self.snapshot,"markupImage").starts_with("data:image/png"),"shortcuts":crate::features::shortcuts(self).into_iter().map(|(b,a)|json!([b,a])).collect::<Vec<_>>(),"findOpen":self.find_open,"performanceVisible":self.screen=="settings" && self.section=="performance" || self.visible_panel_key()=="resources","focusToken":self.focus_serial,"focus":if !self.invalid_field.is_empty() { return_focus(&self.invalid_field) } else { self.focus.as_str() }})
    }
    pub fn visible_panel_key(&self) -> &str {
        if ["browse", "editor"].contains(&self.screen.as_str()) {
            self.panel_key()
        } else {
            ""
        }
    }
    pub fn panel_key(&self) -> &str {
        if self.screen == "editor" {
            text(&self.config()["layout"], "secondaryPanel")
        } else if self.panel == "closed" {
            ""
        } else if !self.panel.is_empty() {
            &self.panel
        } else {
            text(&self.config()["layout"], "secondaryPanel")
        }
    }
    pub fn modal_menu(&self) -> bool {
        ["discard-editor", "clear-history", "reset-modules", "clear-data"].contains(&self.menu.as_str())
            || self.menu.starts_with("delete-")
    }
    fn reorder(&mut self, r: &Value, commands: &mut Vec<Value>) {
        if self.private() {
            return;
        }
        let spaces = text(r, "op") == "reorder-spaces";
        let key = if spaces { "spaces" } else { "folders" };
        let items: Vec<_> = array(&self.snapshot[key])
            .iter()
            .filter(|v| !spaces || v["profileID"] == self.snapshot["session"]["profileID"])
            .collect();
        let id = text(r, "id");
        let before = text(r, "before");
        let mut ids: Vec<_> = items.iter().map(|v| text(v, "id").to_string()).collect();
        let Some(index) = ids.iter().position(|v| v == id) else {
            return;
        };
        if before == id || !before.is_empty() && !ids.iter().any(|v| v == before) {
            return;
        }
        let previous = ids.clone();
        let value = ids.remove(index);
        let target = ids.iter().position(|v| v == before).unwrap_or(ids.len());
        ids.insert(target, value);
        if ids == previous {
            return;
        }
        let op = if spaces {
            "reorderSpaces"
        } else {
            "reorderFolders"
        };
        self.order_undo.push(json!({"op":op,"ids":previous}));
        if self.order_undo.len() > 30 {
            self.order_undo.remove(0);
        }
        commands.push(json!({"op":op,"ids":ids}));
        self.notice = if spaces {
            "Space order updated."
        } else {
            "Folder order updated."
        }
        .into();
        self.menu.clear();
    }
    fn close_screen(&mut self) {
        self.screen = "browse".into();
        self.draft = None;
        self.menu.clear();
        self.undo.clear();
        self.redo.clear();
        self.pending_exit = None;
    }
    fn push_undo(&mut self) {
        self.redo.clear();
        if let Some(value) = &self.draft {
            self.undo.push(value.clone());
            if self.undo.len() > 50 {
                self.undo.remove(0);
            }
        }
    }
    fn edit_value(&mut self, r: &Value) {
        if self.draft.is_none() {
            return;
        }
        let key = text(r, "key");
        let v = &r["value"];
        if key == "themePack" {
            let mut theme = self.draft.as_ref().unwrap()["theme"].clone();
            if crate::appearance::apply_theme_pack(&mut theme, text(r, "value")) && theme != self.draft.as_ref().unwrap()["theme"] {
                self.push_undo();
                self.draft.as_mut().unwrap()["theme"] = theme;
            }
            return;
        }
        let target = match key {
            "accent" | "colorMode" | "density" | "reducedMotion" | "iconPack" | "iconStroke"
            | "cornerRadius" | "fontScale" | "spacingScale" | "typography" | "transparency"
            | "borderWidth" | "shadowStrength" | "accentHex" | "surfaceHex" | "textHex" => "theme",
            "tabsWidth" | "treeTabs" | "bookmarksBar" | "sidebarWidth" | "secondaryPanel" | "toolbarItems"
            | "panelBar" | "statusBar" | "split" | "compactRail" | "hiddenButtons" | "tabThumbnails" => "layout",
            _ => return,
        };
        let valid = match key {
            "accent" => ["rose", "purple", "teal", "blue", "orange", "pink"]
                .contains(&v.as_str().unwrap_or("")),
            "colorMode" => ["system", "light", "dark"].contains(&v.as_str().unwrap_or("")),
            "density" => ["compact", "comfortable"].contains(&v.as_str().unwrap_or("")),
            "iconPack" => {
                ["outline", "precision", "solid", "module"].contains(&v.as_str().unwrap_or(""))
            }
            "typography" => {
                ["system", "rounded", "monospaced", "serif"].contains(&v.as_str().unwrap_or(""))
            }
            "accentHex" | "surfaceHex" | "textHex" => {
                v.as_str().is_some_and(crate::appearance::hex)
            }
            "secondaryPanel" => [
                "",
                "notes",
                "bookmarks",
                "history",
                "downloads",
                "resources",
            ]
            .contains(&v.as_str().unwrap_or("")),
            "toolbarItems" => v.as_array().is_some_and(|items| items.len() <= 14 && items.iter().all(|i| crate::render::TOOLBAR_ITEMS.iter().any(|t| Some(t.0) == i.as_str()))),
            "hiddenButtons" => v.as_array().is_some_and(|items| items.iter().all(|i| crate::render::REMOVABLE_BUTTONS.iter().any(|b| Some(b.0) == i.as_str()))),
            "split" => ["sideBySide", "stacked", "grid"].contains(&v.as_str().unwrap_or("")),
            "cornerRadius" => v.as_f64().is_some_and(|n| (0.0..=24.0).contains(&n)),
            "fontScale" => v.as_f64().is_some_and(|n| (0.85..=1.4).contains(&n)),
            "spacingScale" => v.as_f64().is_some_and(|n| (0.75..=1.5).contains(&n)),
            "borderWidth" => v.as_f64().is_some_and(|n| (0.0..=2.0).contains(&n)),
            "shadowStrength" => v.as_f64().is_some_and(|n| (0.0..=1.0).contains(&n)),
            "iconStroke" => v.as_f64().is_some_and(|n| (1.0..=2.5).contains(&n)),
            "sidebarWidth" => v.as_f64().is_some_and(|n| (180.0..=360.0).contains(&n)),
            "tabsWidth" => v
                .as_f64()
                .map(|x| (200.0..=340.0).contains(&x))
                .unwrap_or(false),
            _ => v.is_boolean(),
        };
        // A named accent replaces a custom accent colour, even when the name itself is unchanged.
        let custom_accent = key == "accent" && !self.draft.as_ref().unwrap()["theme"]["accentHex"].is_null();
        if valid && (self.draft.as_ref().unwrap()[target][key] != *v || custom_accent) {
            let gesture = bound(text(r, "gesture"), 80);
            if gesture.is_empty() || gesture != self.adjustment {
                self.push_undo();
            }
            self.adjustment = gesture;
            let draft = self.draft.as_mut().unwrap();
            draft[target][key] = v.clone();
            // A theme's window colours belong to its own mode; choosing another mode drops them.
            if key == "colorMode" && !draft["theme"]["surfaceHex"].is_null() {
                for k in ["surfaceHex", "textHex", "themePack"] {
                    draft["theme"][k] = Value::Null;
                }
            }
            if key == "accent" {
                draft["theme"]["accentHex"] = Value::Null;
                draft["theme"]["themePack"] = Value::Null;
            }
        }
    }
    fn dock(&mut self, r: &Value) {
        if self.draft.is_none() {
            return;
        }
        let component = text(r, "component");
        let region = text(r, "region");
        if !["leading", "trailing", "top", "bottom"].contains(&region) {
            return;
        }
        if component == "navigation" && !["top", "bottom"].contains(&region)
            || component == "panels" && !["leading", "trailing"].contains(&region)
        {
            self.notice = "This component cannot dock here. Choose a highlighted region.".into();
            return;
        }
        let key = match component {
            "tabs" => "tabs",
            "navigation" => "navigation",
            "panels" => "sidebar",
            _ => return,
        };
        self.push_undo();
        let draft = self.draft.as_mut().unwrap();
        draft["layout"][key] = json!(region);
        if key == "sidebar" && text(&draft["layout"], "secondaryPanel").is_empty() {
            draft["layout"]["secondaryPanel"] = json!("bookmarks");
        }
        if key == "tabs" && ["top", "bottom"].contains(&region) {
            draft["layout"]["treeTabs"] = json!(false);
        }
        self.edit_component = component.into();
        let label = match component {
            "tabs" => "Tabs",
            "navigation" => "Navigation",
            _ => "Library panel",
        };
        let position = match region {
            "leading" => "left",
            "trailing" => "right",
            "top" => "top",
            _ => "bottom",
        };
        self.notice = format!("{label} moved to the {position}.");
    }
    fn move_tab(&mut self, r: &Value, commands: &mut Vec<Value>) {
        let id = text(r, "id");
        let group = text(r, "group");
        if !["pinned", "today", "folder"].contains(&group) {
            return;
        }
        let mut tabs = self.tabs().to_vec();
        let Some(index) = tabs.iter().position(|t| text(t, "id") == id) else {
            return;
        };
        let folder = if group == "folder" {
            let f = text(r, "folderID");
            if !array(&self.snapshot["folders"])
                .iter()
                .any(|v| text(v, "id") == f)
            {
                return;
            }
            json!(f)
        } else {
            Value::Null
        };
        let before = text(r, "before");
        if before == id {
            return;
        }
        if !before.is_empty() && !tabs.iter().any(|t| text(t, "id") == before) {
            return;
        }
        self.order_undo.clear();
        let original = json!(tabs);
        let mut item = tabs.remove(index);
        item["pinned"] = json!(group == "pinned");
        item["folderID"] = folder;
        item["parentID"] = Value::Null;
        let to = if before.is_empty() {
            if group == "pinned" {
                tabs.iter()
                    .position(|t| !flag(t, "pinned"))
                    .unwrap_or(tabs.len())
            } else {
                tabs.len()
            }
        } else {
            tabs.iter().position(|t| text(t, "id") == before).unwrap()
        };
        tabs.insert(to, item);
        tabs.sort_by_key(|t| !flag(t, "pinned"));
        // Children follow a moved parent into its new grouping; tree visibility remains coherent.
        let moved = tabs.iter().find(|t| text(t, "id") == id).unwrap().clone();
        let mut descendants = HashSet::from([id.to_string()]);
        for _ in 0..8 {
            for t in &tabs {
                if descendants.contains(text(t, "parentID")) {
                    descendants.insert(text(t, "id").into());
                }
            }
        }
        for t in &mut tabs {
            if text(t, "id") != id && descendants.contains(text(t, "id")) {
                if group == "pinned" {
                    t["parentID"] = Value::Null;
                } else {
                    t["folderID"] = moved["folderID"].clone();
                }
            }
        }
        if json!(tabs) != original {
            self.tab_undo.push(original);
            if self.tab_undo.len() > 20 {
                self.tab_undo.remove(0);
            }
            commands.push(json!({"op":"replaceTabs","tabs":tabs}));
            self.notice = "Tab moved. Undo is available.".into();
        }
        self.menu.clear();
    }
    pub fn results(&self) -> Vec<Value> {
        let query = self.query.to_lowercase();
        let mut out = vec![];
        for (screen, title) in [
            ("modules", "Modules"),
            ("settings", "Settings"),
            ("extensions", "Extensions"),
            ("editor", "Customize"),
            ("library", "Library"),
            ("recovery", "Recovery"),
        ] {
            if !query.is_empty() && title.to_lowercase().contains(&query) {
                out.push(json!({"kind":"command","title":title,"detail":"Open","value":screen}));
            }
        }
        if !query.is_empty() {
            for (id, label, _, _) in crate::features::ACTIONS {
                if crate::features::action_on(self, id) && label.to_lowercase().contains(&query) && out.iter().filter(|v| v["kind"] == "action").count() < 4 {
                    out.push(json!({"kind":"action","title":label,"detail":"Action","value":id}));
                }
            }
            for chain in array(&self.snapshot["preferences"]["commandChains"]).iter().filter(|_| crate::features::on(self, "command-chains")) {
                if text(chain, "name").to_lowercase().contains(&query) {
                    out.push(json!({"kind":"action","title":chain["name"],"detail":"Command chain","value":chain["id"]}));
                }
            }
        }
        for tab in self.tabs() {
            // An untouched blank tab is not a useful destination.
            if text(tab, "url").is_empty() && text(tab, "title") == "New tab" {
                continue;
            }
            if query.is_empty()
                || text(tab, "title").to_lowercase().contains(&query)
                || text(tab, "url").to_lowercase().contains(&query)
            {
                out.push(json!({"kind":"tab","id":tab["id"],"title":tab["title"],"detail":text(tab,"url"),"url":text(tab,"url"),"faviconDataURL":tab["faviconDataURL"],"value":""}));
                if out.iter().filter(|v| v["kind"] == "tab").count() == 5 {
                    break;
                }
            }
        }
        if !query.is_empty() {
            let open: Vec<String> = self.tabs().iter().map(|t| text(t, "url").to_string()).collect();
            for item in array(&self.snapshot["suggestions"]).iter().filter(|i| !open.iter().any(|u| u == text(i, "url"))).take(4) {
                out.push(json!({"kind":"search","title":item["title"],"detail":text(item,"url"),"url":text(item,"url"),"value":text(item,"url"),"source":text(item,"kind")}));
            }
            out.push(json!({"kind":"search","title":self.query,"detail":"Search or open website","value":self.query}));
            if self.palette_new {
                out.rotate_right(1);
            }
        }
        out
    }
}
fn return_focus(field: &str) -> &str {
    if field == "profile" {
        "setup-profile"
    } else {
        "setup-space"
    }
}
pub fn default_configuration() -> Value {
    crate::appearance::preset("neutrino").unwrap()
}
pub fn resolve_address(input: &str, search: &str) -> Option<String> {
    let value = input.trim();
    if value.is_empty() || value.len() > 8192 || value.chars().any(|c| c.is_control()) {
        return None;
    }
    let parse = |v: &str| -> Option<String> {
        let u = Url::parse(v).ok()?;
        if !["https", "http"].contains(&u.scheme())
            || u.host_str().is_none()
            || !u.username().is_empty()
            || u.password().is_some()
        {
            return None;
        }
        Some(u.to_string())
    };
    if value.contains("://") {
        return parse(value);
    }
    let scheme = value.split(':').next().unwrap_or("").to_ascii_lowercase();
    if ["javascript", "data", "file", "about", "vbscript"].contains(&scheme.as_str())
        && value.contains(':')
    {
        return None;
    }
    if !value.chars().any(char::is_whitespace)
        && (value.contains('.') || value.starts_with("localhost") || value.starts_with('['))
    {
        let host = Url::parse(&format!("http://{value}")).ok()?;
        let local = matches!(host.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
        return parse(&format!(
            "{}://{value}",
            if local { "http" } else { "https" }
        ));
    }
    let base = match search {
        "google" => "https://www.google.com/search",
        "bing" => "https://www.bing.com/search",
        _ => "https://duckduckgo.com/",
    };
    let mut u = Url::parse(base).ok()?;
    u.query_pairs_mut().append_pair("q", value);
    Some(u.to_string().replace('+', "%20"))
}
pub fn validate_ai(provider: &str, endpoint: &str, model: &str) -> bool {
    if endpoint.contains('\\')
        || endpoint.chars().any(char::is_control)
        || endpoint.trim() != endpoint
    {
        return false;
    }
    let Ok(url) = Url::parse(endpoint) else {
        return false;
    };
    if model.trim().is_empty()
        || model.chars().count() > 200
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return false;
    }
    let host = url.host_str().unwrap_or("");
    match provider {
        "openAI" => url.scheme() == "https" && host == "api.openai.com",
        "xAI" => url.scheme() == "https" && host == "api.x.ai",
        "local" => {
            url.scheme() == "https"
                || url.scheme() == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(&host)
        }
        _ => false,
    }
}
