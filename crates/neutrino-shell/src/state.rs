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
    pub query: String,
    pub selected_result: usize,
    pub menu: String,
    pub notice: String,
    pub name: String,
    pub sidebar_hidden: bool,
    pub edit_component: String,
    pub apply_space: bool,
    pub setup_busy: bool,
}
impl Default for Shell {
    fn default() -> Self {
        Self {
            snapshot: json!({}),
            screen: "browse".into(),
            section: "general".into(),
            step: 0,
            setup: json!({"profile":"Personal","space":"Everyday","search":"duckDuckGo","blockTrackers":true,"blockPopups":true,"restoreSession":true,"appearance":"system","accent":"rose","layout":"leading","imported":false}),
            draft: None,
            undo: vec![],
            redo: vec![],
            pending_exit: None,
            invalid_field: String::new(),
            tab_undo: vec![],
            palette: false,
            query: String::new(),
            selected_result: 0,
            menu: String::new(),
            notice: String::new(),
            name: String::new(),
            sidebar_hidden: false,
            edit_component: "tabs".into(),
            apply_space: true,
            setup_busy: false,
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
                && ["downloadCancel", "downloadReveal", "downloadOpen"]
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
                "palette" => {
                    self.palette = true;
                    self.menu.clear();
                    self.query = text(&request, "value").into();
                    self.selected_result = 0;
                }
                "query" => {
                    self.query = bound(text(&request, "value"), 8192);
                    self.selected_result = 0;
                }
                "result-next" => {
                    self.selected_result =
                        (self.selected_result + 1).min(self.results().len().saturating_sub(1));
                }
                "result-previous" => {
                    self.selected_result = self.selected_result.saturating_sub(1);
                }
                "escape" => {
                    if self.palette {
                        self.palette = false;
                    } else if !self.menu.is_empty() {
                        if self.menu == "discard-editor" {
                            self.pending_exit = None;
                        }
                        self.menu.clear();
                    } else if self.screen == "editor"
                        && self.draft.as_ref() != Some(&self.snapshot["configuration"])
                    {
                        self.menu = "discard-editor".into();
                    } else {
                        self.close_screen();
                    }
                }
                "screen" => {
                    let screen = text(&request, "value");
                    if [
                        "browse",
                        "settings",
                        "editor",
                        "library",
                        "modules",
                        "extensions",
                        "assistant",
                        "reader",
                        "recovery",
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
                            if screen == "library" {
                                commands.push(json!({"op":"projectLibrary","section":section}));
                            }
                        }
                    }
                }
                "section" => {
                    self.section = bound(text(&request, "value"), 40);
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
                    } else if let Some(url) = resolve_address(
                        text(&value, "value"),
                        text(&self.snapshot["preferences"], "search"),
                    ) {
                        commands.push(json!({"op":"navigate","url":url}));
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
                "newTab" => {
                    commands.push(json!({"op":"newTab"}));
                    self.palette = true;
                    self.query.clear();
                    self.selected_result = 0;
                    self.screen = "browse".into();
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
                    }
                }
                "switchSpace" => {
                    if !self.private()
                        && array(&self.snapshot["spaces"])
                            .iter()
                            .any(|s| s["id"] == request["id"])
                    {
                        commands.push(json!({"op":op,"id":request["id"]}));
                        self.menu.clear();
                        self.screen = "browse".into();
                    }
                }
                "move-tab" => self.move_tab(&request, &mut commands),
                "undo-tabs" => {
                    if let Some(tabs) = self.tab_undo.pop() {
                        let current: HashSet<_> =
                            self.tabs().iter().map(|t| text(t, "id")).collect();
                        let prior: HashSet<_> =
                            array(&tabs).iter().map(|t| text(t, "id")).collect();
                        if current == prior {
                            commands.push(json!({"op":"replaceTabs","tabs":tabs}));
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
                    } else if ["blockTrackers", "blockPopups", "restoreSession"].contains(&key) {
                        if let Some(v) = request["value"].as_bool() {
                            self.setup[key] = json!(v);
                        }
                    }
                }
                "setup-next" => {
                    if self.step == 1
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
                        self.step = (self.step + 1).min(6);
                    }
                }
                "setup-back" => {
                    self.step = self.step.saturating_sub(1);
                }
                "setup-step" => {
                    self.step = (request["value"].as_u64().unwrap_or(0) as usize).min(6);
                }
                "setup-finish" => {
                    if self.step == 6
                        && !self.setup_busy
                        && !text(&self.setup, "profile").is_empty()
                        && !text(&self.setup, "space").is_empty()
                    {
                        commands.push(json!({"op":"finishSetup","setup":self.setup}));
                        self.setup_busy = true;
                    }
                }
                "importBookmarks" | "defaultBrowser" => {
                    commands.push(json!({"op":op}));
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
                    if let Some(config) = self.draft.take() {
                        let pending = self.pending_exit.take();
                        commands.push(json!({"op":"applyConfiguration","configuration":config,"space":self.apply_space}));
                        self.close_screen();
                        if let Some(pending) = pending {
                            let next = self.dispatch(pending);
                            commands.extend(array(&next["commands"]).iter().cloned());
                        }
                        self.notice = "Appearance saved.".into();
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
                    }
                }
                "back" | "forward" | "reload" | "stop" | "bookmark" | "reopenTab" | "split"
                | "unsplit" | "checkUpdates" | "restartUpdate" | "cancelUpdate" | "newWindow"
                | "privateWindow" | "importModule" | "installExtension" | "webStore" | "reader"
                | "capture" | "exportBookmarks" | "clearHistory" | "signIn" | "disconnectAI"
                | "disableAI" | "cancelAI" | "restoreLayout" | "resetModules" | "retrySave"
                | "showDataFolder" => {
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
                "native" => {
                    // Finite allowlist for identifier-based platform services, never an arbitrary selector.
                    let action = text(&request, "action");
                    if [
                        "downloadCancel",
                        "downloadReveal",
                        "downloadOpen",
                        "removeBookmark",
                        "restoreArchived",
                        "toggleModule",
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
                        "libraryPage",
                        "useWebKit",
                        "reloadTab",
                    ]
                    .contains(&action)
                        && !(self.private()
                            && ["saveNote", "deleteNote", "createNote", "credentialDelete"]
                                .contains(&action))
                    {
                        commands
                            .push(json!({"op":action,"id":request["id"],"value":request["value"]}));
                        if action == "deleteNote" || action == "credentialDelete" {
                            self.menu.clear();
                        }
                    }
                }
                _ => {
                    self.notice = "That action is unavailable.".into();
                }
            }
        }
        self.response(commands)
    }
    fn response(&self, commands: Vec<Value>) -> Value {
        json!({"html":crate::render::render(self).into_string(),"commands":commands,"context":format!("{}:{}",text(&self.snapshot["session"],"profileID"),text(&self.snapshot["session"],"spaceID")),"announce":self.notice,"overlay":self.onboarding() || self.palette || !["browse","library"].contains(&self.screen.as_str()) || !self.menu.is_empty(),"focus":if self.palette { "command-input" } else if !self.invalid_field.is_empty() { return_focus(&self.invalid_field) } else { "" }})
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
        let target = match key {
            "accent" | "colorMode" | "density" => "theme",
            "tabsWidth" | "treeTabs" | "bookmarksBar" => "layout",
            _ => return,
        };
        let valid = match key {
            "accent" => {
                ["rose", "purple", "teal", "blue", "orange"].contains(&v.as_str().unwrap_or(""))
            }
            "colorMode" => ["system", "light", "dark"].contains(&v.as_str().unwrap_or("")),
            "density" => ["compact", "comfortable"].contains(&v.as_str().unwrap_or("")),
            "tabsWidth" => v
                .as_f64()
                .map(|x| (200.0..=340.0).contains(&x))
                .unwrap_or(false),
            _ => v.is_boolean(),
        };
        if valid {
            self.push_undo();
            self.draft.as_mut().unwrap()[target][key] = v.clone();
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
        if key == "tabs" && ["top", "bottom"].contains(&region) {
            draft["layout"]["treeTabs"] = json!(false);
        }
        self.edit_component = component.into();
        self.notice = format!("{} moved to {}.", component, region);
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
        for tab in self.tabs() {
            if query.is_empty()
                || text(tab, "title").to_lowercase().contains(&query)
                || text(tab, "url").to_lowercase().contains(&query)
            {
                out.push(json!({"kind":"tab","id":tab["id"],"title":tab["title"],"detail":text(tab,"url"),"value":""}));
                if out.len() == 5 {
                    break;
                }
            }
        }
        if !query.is_empty() {
            out.push(json!({"kind":"search","title":self.query,"detail":"Search or open website","value":self.query}));
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
    json!({"theme":{"design":"native","accent":"rose","colorMode":"system","density":"comfortable","cornerRadius":12,"transparency":false,"reducedMotion":false,"iconStyle":"outline"},"layout":{"tabs":"leading","navigation":"top","sidebar":"leading","sidebarWidth":260,"bookmarksBar":false,"statusBar":false,"tabsWidth":240}})
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
