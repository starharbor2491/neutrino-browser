// SPDX-License-Identifier: MPL-2.0
//! Shared library, session, tree, split, Space and profile transformations.
use crate::state::{array, flag, text};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
fn id() -> String {
    uuid::Uuid::new_v4().to_string().to_uppercase()
}
fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|v| v.as_secs_f64() - 978_307_200.)
        .unwrap_or(0.)
}
fn tab(engine: &str) -> Value {
    let mut v = json!({"id":id(),"title":"New tab","pinned":false});
    if !engine.is_empty() {
        v["engineID"] = json!(engine);
    }
    v
}
fn web(v: &str) -> bool {
    url::Url::parse(v).is_ok_and(|u| {
        matches!(u.scheme(), "http" | "https")
            && u.host_str().is_some()
            && u.username().is_empty()
            && u.password().is_none()
    })
}
fn title(v: &str) -> String {
    v.chars().take(512).collect()
}
fn unique(items: &[Value], key: &str, max: usize) -> Vec<Value> {
    let mut seen = HashSet::new();
    items
        .iter()
        .filter(|v| seen.insert(text(v, key).to_owned()))
        .take(max)
        .cloned()
        .collect()
}
fn pages(items: &[Value]) -> Vec<Value> {
    items
        .iter()
        .take(200)
        .cloned()
        .map(|mut p| {
            let u = text(&p, "url");
            if !web(u) || u.len() > 8192 {
                p["url"] = Value::Null;
                p["title"] = json!("New tab");
            } else {
                p["title"] = json!(title(text(&p, "title")));
            }
            p
        })
        .collect()
}
fn ancestors(tabs: &[Value], id: &str) -> Vec<String> {
    let mut out = vec![];
    let mut seen = HashSet::from([id.to_owned()]);
    let mut parent = tabs
        .iter()
        .find(|t| t["id"] == id)
        .map(|t| text(t, "parentID").to_owned())
        .unwrap_or_default();
    while !parent.is_empty() && seen.insert(parent.clone()) && out.len() < 8 {
        out.push(parent.clone());
        parent = tabs
            .iter()
            .find(|t| t["id"] == parent)
            .map(|t| text(t, "parentID").to_owned())
            .unwrap_or_default();
    }
    out
}
fn select(mut s: Value, id: &str) -> Value {
    if !array(&s["tabs"]).iter().any(|t| t["id"] == id) {
        return s;
    }
    if s["split"].is_object() && s["split"]["first"] != id && s["split"]["second"] != id {
        let key = if s["selectedTabID"] == s["split"]["second"] {
            "second"
        } else {
            "first"
        };
        s["split"][key] = json!(id);
    }
    s["selectedTabID"] = json!(id);
    let parents = ancestors(array(&s["tabs"]), id);
    if let Some(tabs) = s["tabs"].as_array_mut() {
        for t in tabs {
            if parents.iter().any(|p| t["id"] == *p) {
                t["collapsed"] = json!(false);
            }
        }
    }
    s
}
fn session(mut s: Value) -> Value {
    let mut tabs = unique(array(&s["tabs"]), "id", 200);
    for t in &mut tabs {
        if !t["url"].is_null() && !web(text(t, "url")) {
            t["url"] = Value::Null;
            t["title"] = json!("New tab");
        }
        t["title"] = json!(title(text(t, "title")));
        if t["engineID"] == "chromium" && !t["chromiumPages"].is_null() {
            let saved = pages(array(&t["chromiumPages"]));
            if let Some(first) = saved.first() {
                t["url"] = first["url"].clone();
                t["title"] = first["title"].clone();
            }
            t["chromiumPages"] = if saved.is_empty() {
                Value::Null
            } else {
                json!(saved)
            };
        } else {
            t["chromiumPages"] = Value::Null;
        }
    }
    if tabs.is_empty() {
        tabs.push(tab(""));
    }
    tabs.sort_by_key(|t| !flag(t, "pinned"));
    if !tabs.iter().any(|t| t["id"] == s["selectedTabID"]) {
        s["selectedTabID"] = tabs[0]["id"].clone();
    }
    let ids: HashSet<_> = tabs.iter().map(|t| text(t, "id").to_owned()).collect();
    for i in 0..tabs.len() {
        let mut seen = HashSet::from([text(&tabs[i], "id").to_owned()]);
        let mut parent = text(&tabs[i], "parentID").to_owned();
        let mut depth = 0;
        while !parent.is_empty() {
            depth += 1;
            if !ids.contains(&parent)
                || !seen.insert(parent.clone())
                || depth > 8
                || flag(&tabs[i], "pinned")
            {
                tabs[i]["parentID"] = Value::Null;
                break;
            }
            parent = tabs
                .iter()
                .find(|t| t["id"] == parent)
                .map(|t| text(t, "parentID").to_owned())
                .unwrap_or_default();
        }
    }
    if s["split"].is_object() {
        let a = text(&s["split"], "first");
        let b = text(&s["split"], "second");
        if a == b || !ids.contains(a) || !ids.contains(b) {
            s["split"] = Value::Null;
        } else if s["split"]["first"] != s["selectedTabID"]
            && s["split"]["second"] != s["selectedTabID"]
        {
            s["split"]["first"] = s["selectedTabID"].clone();
        }
    }
    if !s["split"].is_null() {
        s["splitSuppressed"] = Value::Null;
    }
    s["tabs"] = json!(tabs);
    let selected = text(&s, "selectedTabID").to_owned();
    select(s, &selected)
}
use crate::render::MAX_FOLDER_DEPTH;
fn space(mut s: Value) -> Value {
    let name = text(&s, "name").trim().chars().take(80).collect::<String>();
    s["name"] = json!(if name.is_empty() { "Space" } else { &name });
    if text(&s, "symbol").is_empty() || text(&s, "symbol").chars().count() > 80 {
        s["symbol"] = json!("circle.grid.2x2");
    }
    s["tabs"] = session(json!({"tabs":s["tabs"]}))["tabs"].clone();
    let mut folders = unique(array(&s["folders"]), "id", 100);
    for f in &mut folders {
        f["name"] = json!(text(f, "name").chars().take(80).collect::<String>());
    }
    let ids: HashSet<_> = folders.iter().map(|f| text(f, "id").to_owned()).collect();
    // A nested folder's parent must exist, without loops, at most three levels up.
    let parents: HashMap<String, String> = folders.iter().map(|f| (text(f, "id").to_owned(), text(f, "parentID").to_owned())).collect();
    for f in &mut folders {
        let id = text(f, "id").to_owned();
        let mut current = text(f, "parentID").to_owned();
        let mut depth = 0;
        let valid = loop {
            if current.is_empty() {
                break true;
            }
            if current == id || depth >= MAX_FOLDER_DEPTH || !ids.contains(&current) {
                break false;
            }
            current = parents.get(&current).cloned().unwrap_or_default();
            depth += 1;
        };
        if !valid || f["parentID"].as_str() == Some("") {
            f["parentID"] = Value::Null;
        }
    }
    s["folders"] = json!(folders);
    if let Some(tabs) = s["tabs"].as_array_mut() {
        for t in tabs {
            if !t["folderID"].is_null() && !ids.contains(text(t, "folderID")) {
                t["folderID"] = Value::Null;
            }
        }
    }
    if !array(&s["archivedTabs"]).is_empty() {
        let archived = session(json!({"tabs":s["archivedTabs"]}));
        s["archivedTabs"] = json!(array(&archived["tabs"])
            .iter()
            .filter(|t| !array(&s["tabs"]).iter().any(|v| v["id"] == t["id"]))
            .cloned()
            .collect::<Vec<_>>());
    }
    s
}
fn new_space(profile: &Value) -> Value {
    json!({"id":id(),"name":"Personal","symbol":"circle.grid.2x2","profileID":profile["id"],"tabs":[tab(profile["engineID"].as_str().unwrap_or("chromium"))],"folders":[],"archivedTabs":[]})
}
fn spaces(mut s: Value) -> Value {
    if array(&s["profiles"]).is_empty() {
        s["profiles"] = json!([{"id":id(),"name":"Personal","engineID":"chromium"}]);
    }
    let profile_ids: HashSet<_> = array(&s["profiles"])
        .iter()
        .map(|p| text(p, "id").to_owned())
        .collect();
    let setup_ids: HashSet<_> = array(&s["preferences"]["savedConfigurations"])
        .iter()
        .map(|p| text(p, "id").to_owned())
        .collect();
    let valid: Vec<_> = array(&s["spaces"])
        .iter()
        .filter(|p| profile_ids.contains(text(p, "profileID")))
        .cloned()
        .collect();
    let mut valid = unique(&valid, "id", 100);
    if valid.is_empty() {
        valid.push(new_space(&s["profiles"][0]));
    }
    let mut used = HashSet::new();
    for v in &mut valid {
        *v = space(v.clone());
        let mut remapped = HashMap::new();
        if let Some(tabs) = v["tabs"].as_array_mut() {
            for t in tabs.iter_mut() {
                let old = text(t, "id").to_owned();
                if !used.insert(old.clone()) {
                    let replacement = id();
                    t["id"] = json!(replacement);
                    used.insert(replacement.clone());
                    remapped.insert(old, replacement);
                }
            }
            for t in tabs {
                if let Some(new) = remapped.get(text(t, "parentID")) {
                    t["parentID"] = json!(new);
                }
            }
        }
        if let Some(archived) = v["archivedTabs"].as_array_mut() {
            for t in archived {
                if !used.insert(text(t, "id").to_owned()) {
                    let replacement = id();
                    used.insert(replacement.clone());
                    t["id"] = json!(replacement);
                }
            }
        }
        if !v["setupID"].is_null() && !setup_ids.contains(text(v, "setupID")) {
            v["setupID"] = Value::Null;
        }
    }
    if let Some(sessions) = s["sessions"].as_array_mut() {
        for current in sessions {
            if let Some(space) = valid.iter().find(|v| v["id"] == current["spaceID"]) {
                current["profileID"] = space["profileID"].clone();
                current["tabs"] = space["tabs"].clone();
                *current = session(current.clone());
            }
        }
    }
    s["spaces"] = json!(valid);
    s
}
fn configuration(mut c: Value) -> Value {
    c["theme"] = crate::appearance::normalize_theme(c["theme"].clone());
    c["layout"] = crate::appearance::normalize_layout(c["layout"].clone());
    c
}
fn library(mut s: Value) -> Value {
    let mut profiles = unique(array(&s["profiles"]), "id", 20);
    if profiles.is_empty() {
        profiles.push(json!({"id":id(),"name":"Personal","engineID":"chromium"}));
    }
    let ids: HashSet<_> = profiles.iter().map(|p| text(p, "id").to_owned()).collect();
    s["profiles"] = json!(profiles);
    if !s["pendingWebsiteDataClears"].is_null() {
        let mut valid: Vec<_> = array(&s["pendingWebsiteDataClears"])
            .iter()
            .filter_map(Value::as_str)
            .filter(|v| ids.contains(*v))
            .map(str::to_owned)
            .collect();
        valid.sort();
        valid.dedup();
        s["pendingWebsiteDataClears"] = json!(valid);
    }
    if !s["pendingProfileDeletions"].is_null() {
        let mut seen = HashSet::new();
        s["pendingProfileDeletions"] = json!(array(&s["pendingProfileDeletions"])
            .iter()
            .filter(|v| v
                .as_str()
                .is_some_and(|v| !ids.contains(v) && seen.insert(v.to_owned())))
            .take(100)
            .cloned()
            .collect::<Vec<_>>());
    }
    for key in ["bookmarks", "history"] {
        let mut items: Vec<_> = array(&s[key])
            .iter()
            .filter(|v| ids.contains(text(v, "profileID")) && web(text(v, "url")))
            .cloned()
            .collect();
        if key == "history" && items.len() > 10_000 {
            items.drain(..items.len() - 10_000);
        }
        for i in &mut items {
            i["title"] = json!(title(text(i, "title")));
        }
        s[key] = json!(items);
    }
    s["notes"] = json!(array(&s["notes"])
        .iter()
        .filter(|v| ids.contains(text(v, "profileID")))
        .cloned()
        .collect::<Vec<_>>());
    let sessions: Vec<_> = array(&s["sessions"])
        .iter()
        .filter(|v| ids.contains(text(v, "profileID")))
        .cloned()
        .collect();
    s["sessions"] = json!(unique(&sessions, "id", usize::MAX)
        .into_iter()
        .map(session)
        .collect::<Vec<_>>());
    s = spaces(s);
    let valid_spaces: HashMap<_, _> = array(&s["spaces"])
        .iter()
        .map(|v| (text(v, "id").to_owned(), text(v, "profileID").to_owned()))
        .collect();
    if let Some(notes) = s["notes"].as_array_mut() {
        for n in notes {
            if !n["sourceURL"].is_null() && !web(text(n, "sourceURL")) {
                n["sourceURL"] = Value::Null;
            }
            if !n["spaceID"].is_null()
                && valid_spaces
                    .get(text(n, "spaceID"))
                    .is_none_or(|p| p != text(n, "profileID"))
            {
                n["spaceID"] = Value::Null;
            }
            if let Some(q) = n["quotedText"].as_str() {
                n["quotedText"] = json!(q.chars().take(16_000).collect::<String>());
            }
            if let Some(t) = n["sourceTitle"].as_str() {
                n["sourceTitle"] = json!(title(t));
            }
            if text(n, "sourcePageToken").len() > 64 {
                n["sourcePageToken"] = Value::Null;
            }
        }
    }
    s["preferences"]["configuration"] = configuration(s["preferences"]["configuration"].clone());
    if let Some(saved) = s["preferences"]["savedConfigurations"].as_array_mut() {
        for c in saved {
            c["configuration"] = configuration(c["configuration"].clone());
        }
    }
    s
}
fn apply_space_configuration(r: &Value, mut s: Value) -> Result<Value, &'static str> {
    let config = configuration(r["configuration"].clone());
    let space = array(&s["spaces"]).iter().position(|v| v["id"] == r["id"]);
    if let Some(i) = space {
        let setup = s["spaces"][i]["setupID"].clone();
        if let Some(existing) = array(&s["preferences"]["savedConfigurations"])
            .iter()
            .position(|v| v["id"] == setup)
        {
            s["preferences"]["savedConfigurations"][existing]["configuration"] = config;
        } else {
            if array(&s["preferences"]["savedConfigurations"]).len() >= 50 {
                return Err("You have 50 saved setups. Replace or delete one before customizing another Space.");
            }
            let setup = json!({"id":id(),"name":format!("{} setup",text(&s["spaces"][i],"name")),"configuration":config});
            s["spaces"][i]["setupID"] = setup["id"].clone();
            s["preferences"]["savedConfigurations"]
                .as_array_mut()
                .ok_or("Invalid saved setups.")?
                .push(setup);
        }
    } else {
        s["preferences"]["configuration"] = config;
    }
    Ok(s)
}
fn manage_setup(r: &Value, mut s: Value) -> Result<Value, &'static str> {
    let action = text(r, "action");
    let name = text(r, "name").trim();
    let index = array(&s["preferences"]["savedConfigurations"])
        .iter()
        .position(|v| v["id"] == r["id"]);
    if action == "delete" {
        let index = index.ok_or("This setup no longer exists.")?;
        let id = s["preferences"]["savedConfigurations"][index]["id"].clone();
        s["preferences"]["savedConfigurations"]
            .as_array_mut()
            .ok_or("Invalid saved setups.")?
            .remove(index);
        if let Some(spaces) = s["spaces"].as_array_mut() {
            for space in spaces {
                if space["setupID"] == id {
                    space["setupID"] = Value::Null;
                }
            }
        }
    } else if action == "rename" {
        if name.is_empty() || name.chars().count() > 80 {
            return Err("Use a setup name of 1–80 characters.");
        }
        s["preferences"]["savedConfigurations"][index.ok_or("This setup no longer exists.")?]
            ["name"] = json!(name);
    } else if action == "save" || action == "replace" {
        let requirements = array(&r["requirements"]);
        if requirements.len() > 32
            || requirements
                .iter()
                .any(|v| !v.as_str().is_some_and(crate::modules::id))
            || requirements.iter().collect::<HashSet<_>>().len() != requirements.len()
        {
            return Err("Setup module requirements are invalid.");
        }
        let config = configuration(r["configuration"].clone());
        if !config["theme"].is_object() || !config["layout"].is_object() {
            return Err("Invalid appearance configuration.");
        }
        if action == "replace" {
            let setup = &mut s["preferences"]["savedConfigurations"]
                [index.ok_or("This setup no longer exists.")?];
            setup["configuration"] = config;
            setup["requiredModuleIDs"] = json!(requirements);
        } else {
            if name.is_empty() || name.chars().count() > 80 {
                return Err("Use a setup name of 1–80 characters.");
            }
            let saved = s["preferences"]["savedConfigurations"]
                .as_array_mut()
                .ok_or("Invalid saved setups.")?;
            if saved.len() >= 50 {
                return Err(
                    "You have 50 saved setups. Replace or delete one before adding another.",
                );
            }
            saved.push(json!({"id":id(),"name":name,"configuration":config,"requiredModuleIDs":requirements}));
        }
    } else {
        return Err("Unknown setup action.");
    }
    Ok(s)
}
fn webkit_library(mut s: Value) -> Value {
    let mut references = vec![];
    fn convert(list: &mut Value, profile: &Value, references: &mut Vec<Value>) {
        let mut original = array(list).to_vec();
        let mut extra = vec![];
        for current in &mut original {
            if current["engineID"] != "chromium" {
                continue;
            }
            let saved = pages(array(&current["chromiumPages"]));
            if let Some(active) = saved.first() {
                current["url"] = active["url"].clone();
                current["title"] = active["title"].clone();
            }
            for page in saved.iter().skip(1).filter(|p| web(text(p, "url"))) {
                let mut restored = tab("webkit");
                restored["url"] = page["url"].clone();
                restored["title"] = page["title"].clone();
                extra.push(restored);
            }
            current["engineID"] = json!("webkit");
            current["chromiumPages"] = Value::Null;
            if !current["url"].is_null() && !web(text(current, "url")) {
                current["url"] = Value::Null;
                current["title"] = json!("New tab");
            }
        }
        let room = 200usize.saturating_sub(original.len());
        original.extend(extra.iter().take(room).cloned());
        for page in extra.into_iter().skip(room) {
            references.push(json!({"id":id(),"profileID":profile,"title":page["title"],"url":page["url"],"createdAt":now()}));
        }
        *list = json!(original);
    }
    if let Some(profiles) = s["profiles"].as_array_mut() {
        for p in profiles {
            if p["engineID"] == "chromium" {
                p["engineID"] = json!("webkit");
            }
        }
    }
    if let Some(spaces) = s["spaces"].as_array_mut() {
        for space in spaces {
            let profile = space["profileID"].clone();
            convert(&mut space["tabs"], &profile, &mut references);
            convert(&mut space["archivedTabs"], &profile, &mut references);
        }
    }
    let spaces = array(&s["spaces"]).to_vec();
    if let Some(sessions) = s["sessions"].as_array_mut() {
        for current in sessions {
            if let Some(space) = spaces
                .iter()
                .find(|v| v["id"] == current["spaceID"] && v["profileID"] == current["profileID"])
            {
                current["tabs"] = space["tabs"].clone();
            } else {
                let profile = current["profileID"].clone();
                convert(&mut current["tabs"], &profile, &mut references);
            }
            *current = session(current.clone());
        }
    }
    let mut bookmarks = array(&s["bookmarks"]).to_vec();
    let key = |v: &Value| {
        (
            text(v, "profileID").to_owned(),
            text(v, "url").to_owned(),
            text(v, "title").to_owned(),
        )
    };
    let mut known: HashSet<_> = bookmarks.iter().map(key).collect();
    for reference in references {
        if known.insert(key(&reference)) {
            bookmarks.push(reference);
        }
    }
    s["bookmarks"] = json!(bookmarks);
    s
}
fn note_source(r: &Value) -> Result<Value, &'static str> {
    let note = &r["note"];
    let profile = text(r, "profileID");
    let address = text(note, "sourceURL");
    if profile.is_empty() || text(note, "profileID") != profile || !web(address) {
        return Err("This source is not available in the current profile.");
    }
    let spaces: HashSet<_> = array(&r["spaces"])
        .iter()
        .filter(|s| text(s, "profileID") == profile)
        .map(|s| text(s, "id"))
        .filter(|id| !id.is_empty())
        .collect();
    let candidates: Vec<_> = array(&r["candidates"])
        .iter()
        .filter(|c| text(c, "profileID") == profile && spaces.contains(text(c, "spaceID")))
        .collect();
    if let Some(original) = candidates
        .iter()
        .find(|c| text(c, "id") == text(note, "sourceTabID"))
    {
        let pages: Vec<_> = array(&original["pages"])
            .iter()
            .take(200)
            .filter(|p| {
                text(p, "url") == address
                    && p["id"]
                        .as_i64()
                        .is_some_and(|id| id > 0 && id <= i32::MAX as i64)
            })
            .collect();
        let token = text(note, "sourcePageToken");
        let page = pages
            .iter()
            .find(|p| !token.is_empty() && token.len() <= 64 && text(p, "token") == token)
            .or_else(|| pages.first());
        if let Some(page) = page {
            return Ok(
                json!({"spaceID":original["spaceID"],"tabID":original["id"],"pageID":page["id"]}),
            );
        }
        if text(original, "url") == address {
            return Ok(json!({"spaceID":original["spaceID"],"tabID":original["id"]}));
        }
        if array(&original["restorableURLs"]).iter().any(|url| url.as_str() == Some(address)) {
            return Ok(json!({"spaceID":original["spaceID"],"tabID":original["id"],"restoreURL":address}));
        }
    }
    let space = [text(note, "spaceID"), text(r, "spaceID")]
        .into_iter()
        .find(|id| spaces.contains(id))
        .unwrap_or("");
    if let Some(existing) = candidates
        .iter()
        .find(|c| text(c, "spaceID") == space && text(c, "url") == address)
    {
        return Ok(json!({"spaceID":space,"tabID":existing["id"]}));
    }
    Ok(json!({"spaceID":space}))
}

pub fn request(r: &Value) -> Result<Value, &'static str> {
    let s = r["value"].clone();
    let id = text(r, "id");
    Ok(match text(r, "op") {
        "moduleNote" => {
            // Only the edited record crosses the ABI. Typing must never copy
            // unrelated note bodies or return the entire notebook.
            let profile = &r["profileID"];
            let output = &r["output"];
            let mut note = s;
            match text(r, "action") {
                "create" => {
                    if !array(&r["profiles"]).contains(profile) {
                        return Err("This profile no longer exists.");
                    }
                    let title = output["title"]
                        .as_str()
                        .ok_or("The Notes package returned invalid note fields.")?;
                    let body = output["text"]
                        .as_str()
                        .ok_or("The Notes package returned invalid note fields.")?;
                    if title.chars().count() > 100 || body.chars().count() > 200_000 {
                        return Err("The Notes package returned invalid note fields.");
                    }
                    note = json!({"id":self::id(),"profileID":profile,"title":title,"text":body,"modifiedAt":now()});
                }
                "update" => {
                    let field = text(r, "field");
                    if !["title", "text"].contains(&field)
                        || note["id"] != r["id"]
                        || note["profileID"] != *profile
                    {
                        return Err("This note no longer exists in this profile.");
                    }
                    let value = output["value"]
                        .as_str()
                        .ok_or("The Notes package returned an oversized field.")?;
                    if value.chars().count() > if field == "title" { 100 } else { 200_000 } {
                        return Err("The Notes package returned an oversized field.");
                    }
                    note[field] = json!(value);
                    note["modifiedAt"] = json!(now());
                }
                "delete" => {
                    if output["delete"] != true {
                        return Err("The Notes package did not approve this operation.");
                    }
                    return Ok(json!({"remove":true}));
                }
                _ => return Err("Unknown note operation."),
            }
            json!({"note":note,"remove":false})
        }
        "resolveNoteSource" => note_source(r)?,
        "projectNotes" => {
            let query = text(r, "query").trim().to_lowercase();
            let mut notes: Vec<_> = array(&s)
                .iter()
                .filter(|v| {
                    v["profileID"] == r["profileID"]
                        && (flag(r, "all")
                            || text(v, "spaceID").is_empty()
                            || v["spaceID"] == r["spaceID"])
                        && (flag(v, "contentMatch")
                            || ["title", "sourceTitle", "sourceURL", "spaceName"]
                                .iter()
                                .any(|key| text(v, key).to_lowercase().contains(&query)))
                })
                .collect();
            notes.sort_by(|a, b| {
                b["modifiedAt"]
                    .as_f64()
                    .unwrap_or(0.)
                    .total_cmp(&a["modifiedAt"].as_f64().unwrap_or(0.))
                    .then_with(|| text(a, "id").cmp(text(b, "id")))
            });
            json!(notes.iter().map(|v| v["id"].clone()).collect::<Vec<_>>())
        }
        "prepareForChromiumRemoval" => webkit_library(s),
        "applyOrganization" => {
            let proposal = &r["proposal"];
            crate::core::request(
                json!({"op":"validateOrganization","proposal":proposal,"knownTabs":array(&s["tabs"]).iter().map(|v|v["id"].clone()).collect::<Vec<_>>() }),
            )?;
            if array(&s["folders"]).len() + array(&proposal["folders"]).len() > 100 {
                return Err("This Space already has too many folders.");
            }
            let mut s = s;
            for folder in array(&proposal["folders"]) {
                let id = uuid::Uuid::new_v4().to_string().to_uppercase();
                s["folders"]
                    .as_array_mut()
                    .ok_or("Invalid folders.")?
                    .push(json!({"id":id,"name":folder["name"],"collapsed":false}));
                if let Some(tabs) = s["tabs"].as_array_mut() {
                    for t in tabs {
                        if array(&folder["tabIDs"]).iter().any(|v| *v == t["id"]) {
                            t["folderID"] = json!(id);
                        }
                    }
                }
            }
            s
        }
        "liveTabOwnership" => {
            let mut owners = s;
            let tab = text(r, "tab");
            let previous = owners[tab].clone();
            match text(r, "action") {
                "claim" => owners[tab] = r["window"].clone(),
                "release" if owners[tab] == r["window"] => {
                    owners
                        .as_object_mut()
                        .ok_or("Invalid ownership registry.")?
                        .remove(tab);
                }
                _ => {}
            }
            json!({"owners":owners,"owner":previous})
        }
        "applySpaceConfiguration" => apply_space_configuration(r, s)?,
        "manageNamedSetup" => manage_setup(r, s)?,
        "normalizeSession" => session(s),
        "normalizeSpace" => space(s),
        "normalizeSpaces" => spaces(s),
        "normalizeLibrary" => library(s),
        "normalizeChromiumPages" => json!(pages(array(&s))),
        "sessionAncestors" => json!(ancestors(array(&s["tabs"]), id)),
        "selectSessionTab" => select(s, id),
        "visibleTreeTabs" => {
            fn visit(
                tabs: &[Value],
                parent: &Value,
                out: &mut Vec<Value>,
                seen: &mut HashSet<String>,
            ) {
                for t in tabs.iter().filter(|t| t["parentID"] == *parent) {
                    if seen.insert(text(t, "id").to_owned()) {
                        out.push(t.clone());
                        if !flag(t, "collapsed") {
                            visit(tabs, &t["id"], out, seen);
                        }
                    }
                }
            }
            let mut out = vec![];
            visit(
                array(&s["tabs"]),
                &Value::Null,
                &mut out,
                &mut HashSet::new(),
            );
            json!(out)
        }
        "setTabParent" => {
            let mut s = s;
            let parent = r["parentID"].as_str();
            let tabs = array(&s["tabs"]);
            let index = tabs.iter().position(|t| t["id"] == id);
            let depth = parent.map(|p| ancestors(tabs, p).len() + 1).unwrap_or(0);
            let current_depth = ancestors(tabs, id).len();
            let valid = index.is_some_and(|i| !flag(&tabs[i], "pinned"))
                && parent.is_none_or(|p| {
                    p != id
                        && tabs.iter().any(|t| t["id"] == p)
                        && !ancestors(tabs, p).iter().any(|a| a == id)
                })
                && depth <= 8
                && tabs
                    .iter()
                    .filter(|t| ancestors(tabs, text(t, "id")).iter().any(|p| p == id))
                    .all(|t| {
                        ancestors(tabs, text(t, "id"))
                            .len()
                            .saturating_sub(current_depth)
                            + depth
                            <= 8
                    });
            if valid {
                s["tabs"][index.unwrap()]["parentID"] = r["parentID"].clone();
                let selected = text(&s, "selectedTabID").to_owned();
                s = select(s, &selected);
            }
            json!({"value":s,"changed":valid})
        }
        "enableSessionSplit" => {
            let mut s = s;
            if s["split"].is_null() {
                let other = array(&s["tabs"])
                    .iter()
                    .find(|t| t["id"] != s["selectedTabID"])
                    .cloned()
                    .unwrap_or_else(|| tab(r["engine"].as_str().unwrap_or("chromium")));
                if !array(&s["tabs"]).iter().any(|t| t["id"] == other["id"]) {
                    s["tabs"]
                        .as_array_mut()
                        .ok_or("Invalid tab list.")?
                        .push(other.clone());
                }
                s["split"] = json!({"first":s["selectedTabID"],"second":other["id"]});
            }
            s
        }
        "archiveIdleTabs" => {
            let mut s = s;
            let before = r["before"].as_f64().ok_or("Invalid archive date.")?;
            let idle: Vec<_> = array(&s["tabs"])
                .iter()
                .filter(|t| {
                    !flag(t, "pinned")
                        && t["folderID"].is_null()
                        && t["lastUsedAt"].as_f64().is_some_and(|v| v < before)
                })
                .cloned()
                .collect();
            let mut archived = array(&s["archivedTabs"]).to_vec();
            archived.extend(idle.clone());
            let mut tabs: Vec<_> = array(&s["tabs"])
                .iter()
                .filter(|t| !idle.iter().any(|i| i["id"] == t["id"]))
                .cloned()
                .collect();
            if tabs.is_empty() {
                tabs.push(tab(idle
                    .first()
                    .and_then(|v| v["engineID"].as_str())
                    .unwrap_or("chromium")));
            }
            if archived.len() > 200 {
                archived.drain(..archived.len() - 200);
            }
            s["tabs"] = json!(tabs);
            s["archivedTabs"] = json!(archived);
            s
        }
        "restoreArchivedTab" => {
            let mut s = s;
            let index = array(&s["archivedTabs"]).iter().position(|t| t["id"] == id);
            let changed = array(&s["tabs"]).len() < 200 && index.is_some();
            if changed {
                let mut t = s["archivedTabs"]
                    .as_array_mut()
                    .unwrap()
                    .remove(index.unwrap());
                t["lastUsedAt"] = json!(now());
                t["parentID"] = Value::Null;
                s["tabs"].as_array_mut().ok_or("Invalid tab list.")?.push(t);
            }
            json!({"value":s,"changed":changed})
        }
        "spaceConfiguration" => {
            let setup = array(&s["spaces"])
                .iter()
                .find(|v| v["id"] == r["id"])
                .map(|v| v["setupID"].clone())
                .unwrap_or(Value::Null);
            array(&s["preferences"]["savedConfigurations"])
                .iter()
                .find(|v| v["id"] == setup)
                .map(|v| v["configuration"].clone())
                .unwrap_or(s["preferences"]["configuration"].clone())
        }
        "removeProfile" => {
            let mut s = s;
            let target = array(&s["profiles"])
                .iter()
                .find(|p| p["id"] == r["replacement"])
                .cloned();
            let profile = array(&s["profiles"])
                .iter()
                .find(|p| p["id"] == id)
                .cloned();
            if id == text(r, "replacement")
                || target.is_none()
                || profile.is_none()
                || array(&s["profiles"]).len() < 2
            {
                return Err("Choose another profile before deleting this one.");
            }
            let mut removed = json!({"profile":profile});
            for k in ["bookmarks", "history", "notes", "sessions", "spaces"] {
                removed[k] = json!(array(&s[k])
                    .iter()
                    .filter(|v| v["profileID"] == id)
                    .cloned()
                    .collect::<Vec<_>>());
            }
            s["profiles"] = json!(array(&s["profiles"])
                .iter()
                .filter(|p| p["id"] != id)
                .cloned()
                .collect::<Vec<_>>());
            for k in ["bookmarks", "history", "notes", "spaces"] {
                s[k] = json!(array(&s[k])
                    .iter()
                    .filter(|v| v["profileID"] != id)
                    .cloned()
                    .collect::<Vec<_>>());
            }
            if let Some(sessions) = s["sessions"].as_array_mut() {
                for current in sessions {
                    if current["profileID"] == id {
                        let t = tab(target
                            .as_ref()
                            .and_then(|v| v["engineID"].as_str())
                            .unwrap_or("chromium"));
                        *current = json!({"id":current["id"],"profileID":r["replacement"],"tabs":[t.clone()],"selectedTabID":t["id"]});
                    }
                }
            }
            let mut pending = array(&s["pendingProfileDeletions"]).to_vec();
            if !pending.iter().any(|v| v == id) {
                pending.push(json!(id));
            }
            s["pendingProfileDeletions"] = json!(pending);
            s = spaces(s);
            if let Some(space) = array(&s["spaces"])
                .iter()
                .find(|v| v["profileID"] == r["replacement"])
                .cloned()
            {
                if let Some(sessions) = s["sessions"].as_array_mut() {
                    for current in sessions {
                        if array(&removed["sessions"])
                            .iter()
                            .any(|v| v["id"] == current["id"])
                        {
                            current["spaceID"] = space["id"].clone();
                            current["tabs"] = space["tabs"].clone();
                            *current = session(current.clone());
                        }
                    }
                }
            }
            json!({"value":s,"removed":removed})
        }
        "restoreProfile" => {
            let mut s = s;
            let c = &r["contents"];
            let id = text(&c["profile"], "id");
            if !array(&s["profiles"]).iter().any(|p| p["id"] == id) {
                s["profiles"]
                    .as_array_mut()
                    .ok_or("Invalid profile list.")?
                    .push(c["profile"].clone());
                for k in ["bookmarks", "history", "notes", "spaces"] {
                    let mut current = array(&s[k]).to_vec();
                    current.extend(array(&c[k]).to_vec());
                    s[k] = json!(current);
                }
                if let Some(sessions) = s["sessions"].as_array_mut() {
                    for restored in array(&c["sessions"]) {
                        if let Some(old) = sessions.iter_mut().find(|v| v["id"] == restored["id"]) {
                            *old = restored.clone();
                        } else {
                            sessions.push(restored.clone());
                        }
                    }
                }
                s["pendingProfileDeletions"] = json!(array(&s["pendingProfileDeletions"])
                    .iter()
                    .filter(|v| *v != id)
                    .cloned()
                    .collect::<Vec<_>>());
            }
            s
        }
        _ => return Err("Unknown workspace operation."),
    })
}
