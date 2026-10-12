// SPDX-License-Identifier: MPL-2.0
//! Local interaction harness for the exact Rust renderer shipped in the native app.
//! Fixture data is not part of the application and this server is never bundled.
use neutrino_shell::{Shell, CSS, JS};
use serde_json::{json, Value};
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    time::Duration,
};
fn fixture() -> Value {
    json!({
     "completedOnboarding":true,"private":false,"spaceName":"Everyday","profileName":"Personal","blinkAvailable":true,
     "configuration":{"theme":{"design":"graphite","accent":"purple","colorMode":"dark","density":"comfortable","cornerRadius":6},"layout":{"tabs":"leading","tabsWidth":256,"navigation":"top","sidebar":"leading"}},
     "preferences":{"search":"duckDuckGo","restoreSession":true,"blockTrackers":true,"blockPopups":true},
     "session":{"id":"window1","profileID":"profile1","spaceID":"space1","selectedTabID":"tab4","tabs":[
      {"id":"tab1","title":"GitHub","url":"https://github.com/","pinned":true},
      {"id":"tab2","title":"Calendar","url":"https://calendar.google.com/","pinned":true},
      {"id":"tab3","title":"Project board","url":"https://example.com/","pinned":false,"folderID":"folder1"},
      {"id":"tab4","title":"New tab","pinned":false},
      {"id":"tab5","title":"Proton Mail","url":"https://mail.proton.me/","pinned":false},
      {"id":"tab6","title":"Documentation","url":"https://example.org/","pinned":false}
     ]},
     "folders":[{"id":"folder1","name":"Projects","collapsed":false}],
     "spaces":[{"id":"space1","name":"Everyday","profileID":"profile1"},{"id":"space2","name":"Work","profileID":"profile1"}],
     "profiles":[{"id":"profile1","name":"Personal"}],"bookmarks":[],"history":[],"downloads":[],"notes":[],
     "updates":{"version":"Neutrino · interface development","automatic":true,"message":"Automatic updates preserve your browsing data."},"modules":fixture_modules(),"moduleCatalogs":[],"extensions":[]
    })
}
fn fixture_modules() -> Vec<Value> {
    let directory = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../Sources/NeutrinoApp/Resources/Modules");
    let mut modules = vec![];
    if let Ok(entries) = std::fs::read_dir(directory) {
        for entry in entries.flatten() {
            let Ok(data) = std::fs::read(entry.path().join("manifest.json")) else {
                continue;
            };
            let Ok(m) = serde_json::from_slice::<Value>(&data) else {
                continue;
            };
            let settings: Vec<_> = m["settings"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|s| {
                    let mut s = s.clone();
                    s["value"] = s["defaultValue"].clone();
                    s
                })
                .collect();
            modules.push(json!({"id":m["id"],"name":m["name"],"description":m["summary"],"publisher":m["publisher"],"version":m["version"],"availableVersion":m["version"],"capability":m["capability"],"installed":m["defaultInstalled"],"enabled":m["defaultInstalled"],"available":true,"bundled":true,"settings":settings,"dependencies":m["dependencies"],"permission":"","providerName":""}));
        }
    }
    modules.sort_by_key(|m| m["name"].as_str().unwrap_or("").to_string());
    modules
}
fn contributions(shell: &mut Shell) {
    let directory = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../Sources/NeutrinoApp/Resources/Modules");
    let modules = shell.snapshot["modules"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let mut widgets = vec![];
    shell.snapshot["icons"] = json!({});
    shell.snapshot["menuItems"] = json!([]);
    for m in modules.iter().filter(|m| m["enabled"] == true) {
        if let Ok(bytes) = std::fs::read(
            directory
                .join(m["id"].as_str().unwrap_or(""))
                .join("definition.json"),
        ) {
            if let Ok(d) = serde_json::from_slice::<Value>(&bytes) {
                if d["icons"].is_object() {
                    shell.snapshot["icons"] = d["icons"].clone();
                }
                if d["menu"].is_array() {
                    shell.snapshot["menuItems"] = d["menu"].clone();
                }
                if d["widgetTitle"].is_string() {
                    widgets.push(d);
                }
            }
        }
    }
    shell.snapshot["startWidgets"] = json!(widgets);
}
fn effects(shell: &mut Shell, commands: &[Value]) {
    for c in commands {
        let snapshot = &mut shell.snapshot;
        match c["op"].as_str().unwrap_or("") {
            "newTab" => {
                let tabs = snapshot["session"]["tabs"].as_array_mut().unwrap();
                let id = format!(
                    "new-tab-{}",
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap()
                        .as_nanos()
                );
                tabs.push(json!({"id":id,"title":"New tab","pinned":false}));
                snapshot["session"]["selectedTabID"] = json!(id);
            }
            "switchSpace" => {
                if let Some(space) = snapshot["spaces"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|s| s["id"] == c["id"])
                    .cloned()
                {
                    snapshot["session"]["spaceID"] = c["id"].clone();
                    snapshot["spaceName"] = space["name"].clone();
                }
            }
            "reorderSpaces" | "reorderFolders" => {
                let key = if c["op"] == "reorderSpaces" {
                    "spaces"
                } else {
                    "folders"
                };
                let list = snapshot[key].as_array().unwrap().clone();
                snapshot[key] = json!(c["ids"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .filter_map(|id| list.iter().find(|v| v["id"] == *id).cloned())
                    .collect::<Vec<_>>());
            }
            "toggleModule" | "installModule" | "uninstallModule" => {
                if let Some(m) = snapshot["modules"]
                    .as_array_mut()
                    .unwrap()
                    .iter_mut()
                    .find(|m| m["id"] == c["id"])
                {
                    if c["op"] == "toggleModule" {
                        m["enabled"] = json!(!m["enabled"].as_bool().unwrap_or(false));
                    } else {
                        let installed = c["op"] == "installModule";
                        m["installed"] = json!(installed);
                        m["enabled"] = json!(installed);
                    }
                }
            }
            "setModuleSetting" => {
                if let Some(setting) = snapshot["modules"]
                    .as_array_mut()
                    .unwrap()
                    .iter_mut()
                    .find(|m| m["id"] == c["id"])
                    .and_then(|m| m["settings"].as_array_mut())
                    .and_then(|s| s.iter_mut().find(|s| s["id"] == c["key"]))
                {
                    setting["value"] = c["value"].clone();
                }
            }
            "replaceTabs" => snapshot["session"]["tabs"] = c["tabs"].clone(),
            "selectTab" => snapshot["session"]["selectedTabID"] = c["id"].clone(),
            "closeTab" => {
                if let Some(t) = snapshot["session"]["tabs"].as_array_mut() {
                    if t.len() > 1 {
                        t.retain(|x| x["id"] != c["id"]);
                    }
                }
            }
            "sidebarWidth" => snapshot["configuration"]["layout"]["tabsWidth"] = c["value"].clone(),
            "applyConfiguration" => snapshot["configuration"] = c["configuration"].clone(),
            "preference" => {
                snapshot["preferences"][c["key"].as_str().unwrap_or("")] = c["value"].clone();
            }
            "createFolder" => {
                let list = snapshot["folders"].as_array_mut().unwrap();
                list.push(json!({"id":format!("folder{}",list.len()+1),"name":c["name"],"collapsed":false}));
            }
            "toggleFolder" => {
                if let Some(f) = snapshot["folders"]
                    .as_array_mut()
                    .unwrap()
                    .iter_mut()
                    .find(|f| f["id"] == c["id"])
                {
                    f["collapsed"] = json!(!f["collapsed"].as_bool().unwrap_or(false));
                }
            }
            "finishSetup" => {
                snapshot["completedOnboarding"] = json!(true);
                snapshot["spaceName"] = c["setup"]["space"].clone();
                snapshot["profileName"] = c["setup"]["profile"].clone();
                snapshot["configuration"]["theme"]["accent"] = c["setup"]["accent"].clone();
            }
            "importBookmarks" => snapshot["imported"] = json!(true),
            "navigate" => {
                let id = snapshot["session"]["selectedTabID"].clone();
                if let Some(t) = snapshot["session"]["tabs"]
                    .as_array_mut()
                    .unwrap()
                    .iter_mut()
                    .find(|t| t["id"] == id)
                {
                    t["url"] = c["url"].clone();
                    t["title"] = c["url"].clone();
                }
            }
            _ => {}
        }
    }
}
fn serve(mut stream: TcpStream, shell: &mut Shell) -> std::io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(3)))?;
    let mut request = Vec::new();
    let mut buf = [0; 4096];
    let header_end;
    loop {
        let n = stream.read(&mut buf)?;
        if n == 0 {
            return Ok(());
        }
        request.extend_from_slice(&buf[..n]);
        if request.len() > 2_097_152 {
            return Ok(());
        }
        if let Some(at) = request.windows(4).position(|w| w == b"\r\n\r\n") {
            header_end = at + 4;
            break;
        }
    }
    let header = String::from_utf8_lossy(&request[..header_end]);
    let first = header.lines().next().unwrap_or("").to_owned();
    let size = header
        .lines()
        .filter_map(|l| l.split_once(':'))
        .find(|(k, _)| k.eq_ignore_ascii_case("content-length"))
        .and_then(|(_, v)| v.trim().parse::<usize>().ok())
        .unwrap_or(0);
    if size > 2_097_152 {
        return Ok(());
    }
    while request.len() < header_end + size {
        let n = stream.read(&mut buf)?;
        if n == 0 {
            return Ok(());
        }
        request.extend_from_slice(&buf[..n]);
    }
    let path = first.split_whitespace().nth(1).unwrap_or("/");
    let (mime, body) = match path {
        "/neutrino.svg" => ("image/svg+xml", neutrino_shell::LOGO.into()),
        "/shell.css" => ("text/css", CSS.into()),
        "/shell.js" => ("text/javascript", JS.into()),
        "/dispatch" => {
            let request: Value = serde_json::from_slice(&request[header_end..header_end + size])
                .unwrap_or(Value::Null);
            let result = if request["kind"] == "ready" {
                let snapshot = shell.snapshot.clone();
                shell.dispatch(json!({"op":"sync","snapshot":snapshot}))
            } else {
                let result = shell.dispatch(request["request"].clone());
                let commands = result["commands"].as_array().cloned().unwrap_or_default();
                if commands.is_empty() {
                    result
                } else {
                    effects(shell, &commands);
                    contributions(shell);
                    let snapshot = shell.snapshot.clone();
                    shell.dispatch(json!({"op":"sync","snapshot":snapshot}))
                }
            };
            ("application/json", result.to_string())
        }
        "/setup" => {
            shell.snapshot["completedOnboarding"] = json!(false);
            shell.step = 0;
            ("text/html", neutrino_shell::document())
        }
        "/" => {
            shell.snapshot = fixture();
            contributions(shell);
            shell.screen = "browse".into();
            shell.palette = false;
            ("text/html", neutrino_shell::document())
        }
        _ => ("text/plain", "Not found".into()),
    };
    write!(stream,"HTTP/1.1 200 OK\r\nContent-Type: {mime}; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n{body}",body.len())?;
    Ok(())
}
fn main() -> std::io::Result<()> {
    let mut shell = Shell::default();
    shell.snapshot = fixture();
    contributions(&mut shell);
    let listener = TcpListener::bind("127.0.0.1:4317")?;
    eprintln!("Rust interface harness: http://127.0.0.1:4317 (fixture data)");
    for stream in listener.incoming() {
        if let Ok(stream) = stream {
            if let Err(e) = serve(stream, &mut shell) {
                eprintln!("Preview request: {e}");
            }
        }
    }
    Ok(())
}
