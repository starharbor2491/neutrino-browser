// SPDX-License-Identifier: MPL-2.0
//! Local module inventory, dependency/provider policy and recoverable transactions.
//! No network or execution. Native code seals are checked by the platform host.
use crate::{
    modules,
    state::{array, flag, text},
};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};
use uuid::Uuid;
type Result<T> = std::result::Result<T, String>;
const ROLES: &[&str] = &[
    "resourceMonitor",
    "notes",
    "screenshot",
    "focusMode",
    "tabSystem",
    "theme",
    "layout",
    "icons",
    "menu",
];
fn fail<T>(s: &str) -> Result<T> {
    Err(s.into())
}
fn check(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(m) if m.file_type().is_symlink() => {
            fail("Symbolic links are not accepted in module packages.")
        }
        Ok(_) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}
fn size(path: &Path) -> Result<Option<usize>> {
    match fs::symlink_metadata(path) {
        Ok(m) if m.is_file() => Ok(Some(m.len() as usize)),
        Ok(_) => fail("Module payloads must be regular files, not links or directories."),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}
fn read(path: &Path, limit: usize) -> Result<Vec<u8>> {
    if size(path)?.is_none_or(|n| n > limit) {
        return fail("A module file is missing or too large.");
    }
    let mut bytes = vec![];
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|e| e.to_string())?
        .take((limit + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() > limit {
        return fail("Module file is too large.");
    }
    Ok(bytes)
}
fn decode(path: &Path, limit: usize) -> Result<Value> {
    let bytes = read(path, limit)?;
    let source = std::str::from_utf8(&bytes).map_err(|e| e.to_string())?;
    modules::json_bounds(source)?;
    serde_json::from_str(source).map_err(|e| e.to_string())
}
fn write(path: &Path, data: &[u8], mode: u32) -> Result<()> {
    check(path)?;
    let parent = path.parent().ok_or("Invalid module storage path.")?;
    check(parent)?;
    let temporary = parent.join(format!(".write-{}", Uuid::new_v4()));
    let work = (|| {
        let mut f = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(mode)
            .open(&temporary)
            .map_err(|e| e.to_string())?;
        f.write_all(data).map_err(|e| e.to_string())?;
        f.sync_all().map_err(|e| e.to_string())?;
        fs::rename(&temporary, path).map_err(|e| e.to_string())?;
        File::open(parent)
            .and_then(|f| f.sync_all())
            .map_err(|e| e.to_string())?;
        Ok(())
    })();
    if work.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    work
}
fn write_json(path: &Path, value: &Value) -> Result<()> {
    write(
        path,
        &serde_json::to_vec(value).map_err(|e| e.to_string())?,
        0o600,
    )
}
fn mkdir(path: &Path) -> Result<()> {
    check(path)?;
    fs::create_dir_all(path).map_err(|e| e.to_string())?;
    check(path)
}
fn remove(path: &Path) -> Result<()> {
    check(path)?;
    match fs::symlink_metadata(path) {
        Ok(m) if m.is_dir() => fs::remove_dir_all(path).map_err(|e| e.to_string()),
        Ok(_) => fs::remove_file(path).map_err(|e| e.to_string()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}
fn entries(root: &Path) -> Result<Vec<PathBuf>> {
    fs::read_dir(root)
        .map_err(|e| e.to_string())?
        .map(|e| e.map(|e| e.path()).map_err(|e| e.to_string()))
        .collect()
}
fn selector(role: &str) -> String {
    if role == "resourceMonitor" {
        ".resource-provider.json".into()
    } else {
        format!(".role-{role}.json")
    }
}
fn selectors() -> Vec<String> {
    ROLES.iter().map(|r| selector(r)).collect()
}
fn token(name: &str, prefix: &str) -> bool {
    name.strip_prefix(prefix)
        .is_some_and(|v| v.len() == 36 && Uuid::parse_str(v).is_ok())
}
fn manifest(path: &Path) -> Result<Value> {
    let m = decode(path, 32 * 1024)?;
    modules::manifest(&m)?;
    Ok(m)
}
fn depends(m: &Value, id: &str, all: &[Value]) -> bool {
    let mut pending = array(&m["dependencies"]).to_vec();
    let mut seen = HashSet::new();
    while let Some(v) = pending.pop() {
        if v == id {
            return true;
        }
        if seen.insert(v.clone().to_string()) {
            if let Some(d) = all.iter().find(|x| x["manifest"]["id"] == v) {
                pending.extend(array(&d["manifest"]["dependencies"]).to_vec());
            }
        }
    }
    false
}
fn dependencies(m: &Value, all: &[Value]) -> bool {
    array(&m["dependencies"]).iter().all(|d| {
        all.iter().any(|v| {
            v["manifest"]["id"] == *d
                && flag(v, "enabled")
                && v["manifest"]["version"].as_u64().unwrap_or(0)
                    >= m["dependencyVersions"][d.as_str().unwrap_or("")]
                        .as_u64()
                        .unwrap_or(1)
        })
    })
}
fn no_dependents(id: &str, all: &[Value]) -> Result<()> {
    if all.iter().any(|m| {
        array(&m["manifest"]["dependencies"])
            .iter()
            .any(|d| d == id)
    }) {
        fail("Remove or disable modules that depend on this provider first.")
    } else {
        Ok(())
    }
}
fn inventory(root: &Path) -> Result<Vec<Value>> {
    let folders: Vec<_> = entries(root)?
        .into_iter()
        .filter(|p| {
            !p.file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .starts_with('.')
        })
        .collect();
    if folders.len() > 512 {
        return fail("The installed module inventory exceeds its size limit.");
    }
    let mut all = vec![];
    for path in folders {
        check(&path)?;
        if !path.is_dir() {
            continue;
        }
        let id = path
            .file_name()
            .unwrap_or_default()
            .to_str()
            .ok_or("Invalid module folder.")?;
        if !modules::id(id) {
            return fail("Invalid installed module ID.");
        }
        let m = manifest(&path.join("manifest.json"))?;
        if m["id"] != id {
            return fail("Module folder and manifest IDs do not match.");
        }
        let receipt = decode(&path.join("receipt.json"), 1024)?;
        if !receipt["enabled"].is_boolean() {
            return fail("Invalid module receipt.");
        }
        let payload = payload_name(&m);
        let bytes = if payload.is_empty() {
            0
        } else {
            size(&path.join(payload))?.unwrap_or(0)
        };
        all.push(json!({"manifest":m,"enabled":receipt["enabled"],"payloadSHA256":receipt["payloadSHA256"],"diskBytes":size(&path.join("manifest.json"))?.unwrap_or(0)+size(&path.join("receipt.json"))?.unwrap_or(0)+bytes}));
    }
    all.sort_by(|a, b| text(&a["manifest"], "name").cmp(text(&b["manifest"], "name")));
    for role in ROLES {
        let file = root.join(selector(role));
        let chosen = if file.exists() {
            let v = decode(&file, 1024)?;
            let id = v.as_str().ok_or("Invalid module provider selection.")?;
            if !id.is_empty() && !modules::id(id) {
                return fail("Invalid module provider selection.");
            }
            Some(id.to_owned())
        } else {
            None
        };
        let chosen = chosen.or_else(|| {
            all.iter()
                .find(|m| {
                    flag(m, "enabled")
                        && text(&m["manifest"], "capability") == *role
                        && if *role == "resourceMonitor" {
                            flag(&m["manifest"], "defaultInstalled")
                        } else {
                            !m["manifest"]["runtime"].is_null()
                        }
                })
                .or_else(|| {
                    all.iter()
                        .find(|m| flag(m, "enabled") && text(&m["manifest"], "capability") == *role)
                })
                .map(|m| text(&m["manifest"], "id").to_owned())
        });
        for m in &mut all {
            if text(&m["manifest"], "capability") == *role {
                m["enabled"] = json!(chosen.as_deref() == Some(text(&m["manifest"], "id")));
            }
        }
    }
    for _ in 0..all.len() {
        let disabled: Vec<_> = all
            .iter()
            .filter(|m| {
                flag(m, "enabled")
                    && (depends(&m["manifest"], text(&m["manifest"], "id"), &all)
                        || !dependencies(&m["manifest"], &all))
            })
            .map(|m| m["manifest"]["id"].clone())
            .collect();
        if disabled.is_empty() {
            break;
        }
        for m in &mut all {
            if disabled.contains(&m["manifest"]["id"]) {
                m["enabled"] = json!(false);
            }
        }
    }
    Ok(all)
}
fn payload_name(m: &Value) -> &str {
    match text(m, "runtime") {
        "nativeResourceWorker" | "nativeReaderWorker" => "worker",
        "behaviorProgram" => "program.json",
        "declarative" => "definition.json",
        _ => "",
    }
}
fn payload(root: &Path, id: &str, runtime: &str, enabled: bool) -> Result<Vec<u8>> {
    let all = inventory(root)?;
    let m = all
        .iter()
        .find(|m| m["manifest"]["id"] == id)
        .ok_or("This module is not installed.")?;
    payload_for(root, m, runtime, enabled)
}
fn payload_for(root: &Path, m: &Value, runtime: &str, enabled: bool) -> Result<Vec<u8>> {
    let id = text(&m["manifest"], "id");
    if text(&m["manifest"], "runtime") != runtime || enabled && !flag(m, "enabled") {
        return fail("This module package is not enabled.");
    }
    let p = read(
        &root.join(id).join(payload_name(&m["manifest"])),
        128 * 1024,
    )?;
    if p.is_empty() || text(m, "payloadSHA256") != format!("{:x}", Sha256::digest(&p)) {
        return fail(
            "The module payload differs from its installation receipt. Reinstall its package.",
        );
    }
    Ok(p)
}
fn validate_payload(m: &Value, p: Option<&[u8]>) -> Result<()> {
    match text(m, "runtime") {
        "nativeResourceWorker" | "nativeReaderWorker" => {
            if p.is_none_or(|p| p.is_empty() || p.len() > 8 * 1024 * 1024) {
                return fail("A native package needs its executable payload (up to 8 MB).");
            }
        }
        "behaviorProgram" | "declarative" => {
            let p = p.ok_or("This package needs its data payload.")?;
            if p.len() > 128 * 1024 {
                return fail("Module data payload exceeds 128 KB.");
            }
            let s = std::str::from_utf8(p).map_err(|e| e.to_string())?;
            modules::json_bounds(s)?;
            let v: Value = serde_json::from_str(s).map_err(|e| e.to_string())?;
            if text(m, "runtime") == "behaviorProgram" {
                modules::validate(&v, text(m, "capability"))?;
            } else {
                modules::definition(&v, text(m, "capability"))?;
            }
        }
        _ => {
            if p.is_some() {
                return fail("Descriptor packages cannot contain payloads.");
            }
        }
    }
    Ok(())
}
fn recover_install(root: &Path) -> Result<()> {
    let file = root.join(".transaction.json");
    if !file.exists() {
        check(&file)?;
        return Ok(());
    }
    let j = decode(&file, 1024)?;
    let id = text(&j, "id");
    if !modules::id(id)
        || !token(text(&j, "stage"), ".stage-")
        || !token(text(&j, "backup"), ".backup-")
    {
        return fail("An interrupted module update has an invalid journal.");
    }
    let destination = root.join(id);
    let stage = root.join(text(&j, "stage"));
    let backup = root.join(text(&j, "backup"));
    for p in [&destination, &stage, &backup] {
        check(p)?;
    }
    if !destination.exists() {
        if backup.exists() {
            fs::rename(&backup, &destination).map_err(|e| e.to_string())?;
        } else if stage.exists() {
            if manifest(&stage.join("manifest.json"))?["id"] != id {
                return fail("Interrupted installation metadata does not match.");
            }
            fs::rename(&stage, &destination).map_err(|e| e.to_string())?;
        }
    }
    remove(&stage)?;
    remove(&backup)?;
    remove(&file)
}
fn copy_directory(from: &Path, to: &Path) -> Result<()> {
    check(from)?;
    mkdir(to)?;
    for path in entries(from)? {
        if size(&path)?.is_none() {
            return fail("Missing module backup file.");
        }
        let name = path.file_name().ok_or("Invalid backup file.")?;
        let limit = match name.to_str() {
            Some("worker") => 8 * 1024 * 1024,
            Some("manifest.json") => 32 * 1024,
            Some("receipt.json") => 1024,
            Some("program.json" | "definition.json") => 128 * 1024,
            _ => return fail("Unexpected file in module backup."),
        };
        let bytes = read(&path, limit)?;
        let mode = fs::metadata(&path)
            .map_err(|e| e.to_string())?
            .permissions()
            .mode()
            & 0o777;
        write(&to.join(name), &bytes, mode)?;
    }
    Ok(())
}
fn recover_batch(root: &Path) -> Result<()> {
    let file = root.join(".batch-transaction.json");
    if !file.exists() {
        check(&file)?;
        return Ok(());
    }
    let j = decode(&file, 32 * 1024)?;
    let items = array(&j["entries"]);
    let present = j["selectors"]
        .as_object()
        .ok_or("Invalid module recovery selectors.")?;
    let absent = array(&j["absentSelectors"]);
    let names = selectors();
    let mut keys: HashSet<_> = present.keys().map(String::as_str).collect();
    if !token(text(&j, "directory"), ".batch-")
        || items.is_empty()
        || items.len() > 128
        || items
            .iter()
            .any(|v| !modules::id(text(v, "id")) || !v["existed"].is_boolean())
        || items
            .iter()
            .map(|v| text(v, "id"))
            .collect::<HashSet<_>>()
            .len()
            != items.len()
        || absent
            .iter()
            .any(|v| v.as_str().is_none_or(|v| !keys.insert(v)))
        || keys != names.iter().map(String::as_str).collect()
    {
        return fail("An interrupted module operation has an invalid recovery journal.");
    }
    let backup = root.join(text(&j, "directory"));
    check(&backup)?;
    if !backup.is_dir() {
        return fail("Module recovery backups are missing.");
    }
    let mut saved = HashMap::new();
    for (name, value) in present {
        let data = STANDARD
            .decode(value.as_str().ok_or("Invalid selector backup.")?)
            .map_err(|e| e.to_string())?;
        if data.len() > 1024 {
            return fail("Module selector backup is too large.");
        }
        saved.insert(name, data);
    }
    for item in items.iter().filter(|v| flag(v, "existed")) {
        let path = backup.join(text(item, "id"));
        check(&path)?;
        if manifest(&path.join("manifest.json"))?["id"] != item["id"] {
            return fail("Module recovery metadata is invalid.");
        }
        for p in entries(&path)? {
            check(&p)?;
            let _ = size(&p)?;
        }
    }
    for item in items {
        let destination = root.join(text(item, "id"));
        if flag(item, "existed") {
            let restore = root.join(format!(".restore-{}", Uuid::new_v4()));
            copy_directory(&backup.join(text(item, "id")), &restore)?;
            remove(&destination)?;
            fs::rename(&restore, &destination).map_err(|e| e.to_string())?;
        } else {
            remove(&destination)?;
        }
    }
    for (name, data) in saved {
        write(&root.join(name), &data, 0o600)?;
    }
    for name in absent {
        remove(&root.join(name.as_str().unwrap_or("")))?;
    }
    remove(&file)?;
    remove(&backup)
}
fn begin_batch(root: &Path, ids: &Value) -> Result<()> {
    let ids = ids.as_array().ok_or("Invalid module transaction.")?;
    if ids.is_empty()
        || ids.len() > 128
        || ids.iter().any(|v| !v.as_str().is_some_and(modules::id))
        || ids.iter().collect::<HashSet<_>>().len() != ids.len()
    {
        return fail("A module transaction exceeds its package limit.");
    }
    let file = root.join(".batch-transaction.json");
    check(&file)?;
    if file.exists() {
        return fail("Another module operation is pending. Relaunch to recover it.");
    }
    recover_install(root)?;
    let all = inventory(root)?;
    let directory = format!(".batch-{}", Uuid::new_v4());
    let backup = root.join(&directory);
    mkdir(&backup)?;
    let mut items = vec![];
    let mut total = 0;
    let result = (|| {
        for id in ids {
            let id = id.as_str().unwrap();
            let existing = all.iter().any(|m| m["manifest"]["id"] == id);
            items.push(json!({"id":id,"existed":existing}));
            if existing {
                let path = root.join(id);
                for p in entries(&path)? {
                    total += size(&p)?.unwrap_or(0);
                }
                if total > 128 * 1024 * 1024 {
                    return fail("This operation exceeds the 128 MB backup limit.");
                }
                copy_directory(&path, &backup.join(id))?;
            }
        }
        let mut saved = serde_json::Map::new();
        let mut absent = vec![];
        for name in selectors() {
            let path = root.join(&name);
            check(&path)?;
            if path.exists() {
                saved.insert(name, json!(STANDARD.encode(read(&path, 1024)?)));
            } else {
                absent.push(name);
            }
        }
        write_json(
            &file,
            &json!({"directory":directory,"entries":items,"selectors":saved,"absentSelectors":absent}),
        )
    })();
    if result.is_err() {
        let _ = remove(&backup);
    }
    result
}
fn settings_path(root: &Path, id: &str) -> Result<PathBuf> {
    if !modules::id(id) {
        return fail("Invalid module ID.");
    }
    let directory = root
        .parent()
        .ok_or("Invalid module storage.")?
        .join("ModuleData");
    mkdir(&directory)?;
    let path = directory.join(format!("{id}.json"));
    check(&path)?;
    Ok(path)
}
fn settings(root: &Path, id: &str) -> Result<Value> {
    let all = inventory(root)?;
    let m = all
        .iter()
        .find(|m| m["manifest"]["id"] == id)
        .ok_or("This module is not installed.")?;
    settings_for(root, m)
}
fn settings_for(root: &Path, m: &Value) -> Result<Value> {
    let id = text(&m["manifest"], "id");
    let mut values = serde_json::Map::new();
    let path = settings_path(root, id)?;
    let saved = if path.exists() {
        let v = decode(&path, 64 * 1024)?;
        modules::value(&v, 0)?;
        v
    } else {
        json!({})
    };
    for schema in array(&m["manifest"]["settings"]) {
        let k = text(schema, "id");
        let v = if !saved[k].is_null() && modules::setting(schema, &saved[k]).is_ok() {
            saved[k].clone()
        } else {
            schema["defaultValue"].clone()
        };
        values.insert(k.into(), v);
    }
    Ok(Value::Object(values))
}
fn catalogs(root: &Path) -> Result<Vec<(PathBuf, Value)>> {
    let paths: Vec<_> = entries(root)?
        .into_iter()
        .filter(|p| {
            p.file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .starts_with(".catalog-")
                && p.extension().is_some_and(|v| v == "json")
        })
        .collect();
    if paths.len() > 16 {
        return fail("Too many community catalogs.");
    }
    paths
        .into_iter()
        .map(|p| {
            let v = decode(&p, 2 * 1024 * 1024)?;
            validate_catalog(&v)?;
            Ok((p, v))
        })
        .collect()
}
pub(crate) fn validate_catalog(c: &Value) -> Result<()> {
    let p = array(&c["packages"]);
    if c["formatVersion"] != 1
        || text(c, "name").is_empty()
        || text(c, "name").chars().count() > 100
        || p.len() > 64
        || p.iter()
            .map(|p| text(&p["manifest"], "id"))
            .collect::<HashSet<_>>()
            .len()
            != p.len()
    {
        return fail("Invalid community catalog.");
    }
    if let Some(source) = c["sourceURL"].as_str() {
        let u = url::Url::parse(source).map_err(|e| e.to_string())?;
        if u.scheme() != "https"
            || u.host_str().is_none()
            || !u.username().is_empty()
            || u.password().is_some()
        {
            return fail("Catalog sources require HTTPS without credentials.");
        }
    }
    for p in p {
        community_payload(p)?;
    }

    Ok(())
}
pub(crate) fn community_payload(p: &Value) -> Result<Value> {
    let m = &p["manifest"];
    modules::manifest(m)?;
    let value = match text(m, "runtime") {
        "declarative" if p["program"].is_null() => &p["definition"],
        "behaviorProgram" if p["definition"].is_null() => &p["program"],
        _ => return fail("Community packages cannot contain native code or descriptors."),
    };
    let bytes = serde_json::to_vec(value).map_err(|e| e.to_string())?;
    validate_payload(m, Some(&bytes))?;
    Ok(value.clone())
}
pub(crate) fn community_request(r: &Value) -> Value {
    match if text(r, "op") == "communityPayload" {
        community_payload(&r["package"])
    } else {
        validate_catalog(&r["catalog"]).map(|_| json!(true))
    } {
        Ok(v) => json!({"result":v}),
        Err(e) => json!({"error":e}),
    }
}
pub fn request(r: &Value) -> Value {
    match dispatch(r) {
        Ok(v) => json!({"result":v}),
        Err(e) => json!({"error":e}),
    }
}
fn dispatch(r: &Value) -> Result<Value> {
    let root = Path::new(text(r, "root"));
    if !root.is_absolute() {
        return fail("Module storage must use an absolute path.");
    }
    mkdir(root)?;
    let id = text(r, "id");
    match text(r, "action") {
        "initialize" => {
            recover_install(root)?;
            // A receipt update may crash before its atomic rename. Its scratch
            // file is never committed state and must not block a later backup.
            for package in entries(root)? {
                let name = package.file_name().unwrap_or_default().to_string_lossy();
                if modules::id(&name) {
                    check(&package)?;
                    if package.is_dir() {
                        for p in entries(&package)? {
                            if token(
                                &p.file_name().unwrap_or_default().to_string_lossy(),
                                ".write-",
                            ) {
                                remove(&p)?;
                            }
                        }
                    }
                }
            }
            recover_batch(root)?;
            for p in entries(root)? {
                let name = p.file_name().unwrap_or_default().to_string_lossy();
                if [".batch-", ".stage-", ".backup-", ".restore-", ".write-"]
                    .iter()
                    .any(|prefix| token(&name, prefix))
                {
                    remove(&p)?;
                }
            }
            let data = root
                .parent()
                .ok_or("Invalid module storage.")?
                .join("ModuleData");
            check(&data)?;
            if data.is_dir() {
                for p in entries(&data)? {
                    if token(
                        &p.file_name().unwrap_or_default().to_string_lossy(),
                        ".write-",
                    ) {
                        remove(&p)?;
                    }
                }
            }
        }
        "installed" => return Ok(json!(inventory(root)?)),
        "presentation" => {
            // Read the inventory once. This projection is presentation data,
            // never an execution permit; execution still checks fresh receipts.
            let mut values = serde_json::Map::new();
            let mut definitions = serde_json::Map::new();
            let mut errors = serde_json::Map::new();
            for m in inventory(root)? {
                let id = text(&m["manifest"], "id");
                match settings_for(root, &m) {
                    Ok(v) => {
                        values.insert(id.into(), v);
                    }
                    Err(e) => {
                        errors.insert(id.into(), json!(e));
                    }
                }
                if flag(&m, "enabled") && m["manifest"]["runtime"] == "declarative" {
                    let result = (|| -> Result<Value> {
                        let bytes = payload_for(root, &m, "declarative", true)?;
                        validate_payload(&m["manifest"], Some(&bytes))?;
                        serde_json::from_slice(&bytes).map_err(|e| e.to_string())
                    })();
                    match result {
                        Ok(v) => {
                            definitions.insert(id.into(), v);
                        }
                        Err(e) => {
                            errors.insert(id.into(), json!(e));
                        }
                    }
                }
            }
            return Ok(json!({"settings":values,"definitions":definitions,"errors":errors}));
        }
        "requirements" => return modules::requirements(r, &json!(inventory(root)?)),
        "plan" => {
            return modules::plan(
                id,
                &r["catalog"],
                &json!(inventory(root)?),
                flag(r, "includeInstalled"),
            )
            .map_err(String::from)
        }
        "begin" => begin_batch(root, &r["ids"])?,
        "commit" => {
            let path = root.join(".batch-transaction.json");
            let j = decode(&path, 32 * 1024)?;
            if !token(text(&j, "directory"), ".batch-") {
                return fail("Invalid module transaction backup.");
            }
            remove(&path)?;
            let _ = remove(&root.join(text(&j, "directory")));
        }
        "rollback" => {
            recover_install(root)?;
            recover_batch(root)?;
        }
        "install" => {
            let m = &r["manifest"];
            modules::manifest(m)?;
            let bytes = r["payload"]
                .as_str()
                .map(|s| STANDARD.decode(s).map_err(|e| e.to_string()))
                .transpose()?;
            validate_payload(m, bytes.as_deref())?;
            recover_install(root)?;
            let all = inventory(root)?;
            let id = text(m, "id");
            let role = text(m, "capability");
            let exclusive = ROLES.contains(&role);
            let provider = all.iter().any(|v| {
                exclusive
                    && flag(v, "enabled")
                    && text(&v["manifest"], "capability") == role
                    && v["manifest"]["id"] != id
                    && (m["runtime"].is_null() || !v["manifest"]["runtime"].is_null())
            });
            let active = r["enabled"]
                .as_bool()
                .or_else(|| {
                    all.iter()
                        .find(|v| v["manifest"]["id"] == id)
                        .and_then(|v| v["enabled"].as_bool())
                })
                .unwrap_or(!provider);
            let stage_name = format!(".stage-{}", Uuid::new_v4());
            let backup_name = format!(".backup-{}", Uuid::new_v4());
            let stage = root.join(&stage_name);
            let backup = root.join(&backup_name);
            let destination = root.join(id);
            mkdir(&stage)?;
            let staged = (|| -> Result<()> {
                write_json(&stage.join("manifest.json"), m)?;
                write_json(
                    &stage.join("receipt.json"),
                    &json!({"enabled":active,"payloadSHA256":bytes.as_ref().map(|b|format!("{:x}",Sha256::digest(b)))}),
                )?;
                if let Some(b) = bytes {
                    write(
                        &stage.join(payload_name(m)),
                        &b,
                        if payload_name(m) == "worker" {
                            0o700
                        } else {
                            0o600
                        },
                    )?;
                }
                Ok(())
            })();
            if let Err(error) = staged {
                let _ = remove(&stage);
                return Err(error);
            }
            write_json(
                &root.join(".transaction.json"),
                &json!({"id":id,"stage":stage_name,"backup":backup_name}),
            )?;
            check(&destination)?;
            if destination.exists() {
                fs::rename(&destination, &backup).map_err(|e| e.to_string())?;
            }
            fs::rename(&stage, &destination).map_err(|e| e.to_string())?;
            remove(&backup)?;
            remove(&root.join(".transaction.json"))?;
            if exclusive && !provider {
                write_json(
                    &root.join(selector(role)),
                    &json!(if active { id } else { "" }),
                )?;
            }
        }
        "setEnabled" | "replace" => {
            let all = inventory(root)?;
            let m = all
                .iter()
                .find(|v| v["manifest"]["id"] == id)
                .ok_or("Module is not installed.")?;
            let role = text(&m["manifest"], "capability");
            let active = if text(r, "action") == "replace" {
                true
            } else {
                flag(r, "enabled")
            };
            let replace = text(r, "action") == "replace";
            if replace && (!ROLES.contains(&role) || text(r, "role") != role) {
                return fail("Choose an installed provider for this exclusive role.");
            }
            if active && !dependencies(&m["manifest"], &all) {
                return fail("Enable this provider's dependencies first.");
            }
            if !active {
                let enabled: Vec<_> = all.iter().filter(|m| flag(m, "enabled")).cloned().collect();
                no_dependents(id, &enabled)?;
                if role == "tabSystem" && flag(m, "enabled") {
                    return fail(
                        "Replace the active tab system before disabling it. Your tabs are kept.",
                    );
                }
            }
            if replace {
                if role == "resourceMonitor" {
                    if m["manifest"]["runtime"] != "nativeResourceWorker" {
                        return fail("Choose an installed native resource provider.");
                    }
                } else {
                    let runtime = text(&m["manifest"], "runtime");
                    if !["behaviorProgram", "declarative"].contains(&runtime) {
                        return fail("Choose a compatible data provider.");
                    }
                    let bytes = payload(root, id, runtime, false)?;
                    validate_payload(&m["manifest"], Some(&bytes))?;
                }
            }
            for previous in all.iter().filter(|p| {
                active
                    && flag(p, "enabled")
                    && text(&p["manifest"], "capability") == role
                    && p["manifest"]["id"] != id
            }) {
                if ROLES.contains(&role) {
                    if !replace {
                        return fail("Choose Replace to switch the current provider.");
                    }
                    let old = text(&previous["manifest"], "id");
                    if depends(&m["manifest"], old, &all) {
                        return fail("A replacement cannot depend on the provider it replaces.");
                    }
                    no_dependents(
                        old,
                        &all.iter()
                            .filter(|m| flag(m, "enabled"))
                            .cloned()
                            .collect::<Vec<_>>(),
                    )?;
                }
            }
            if ROLES.contains(&role) {
                if active || flag(m, "enabled") {
                    write_json(
                        &root.join(selector(role)),
                        &json!(if active { id } else { "" }),
                    )?;
                }
            } else {
                write_json(
                    &root.join(id).join("receipt.json"),
                    &json!({"enabled":active,"payloadSHA256":m["payloadSHA256"]}),
                )?;
            }
        }
        "payload" => {
            return Ok(json!(STANDARD.encode(payload(
                root,
                id,
                text(r, "runtime"),
                flag(r, "requireEnabled")
            )?)))
        }
        "settings" => return settings(root, id),
        "setSetting" => {
            let all = inventory(root)?;
            let schema = all
                .iter()
                .find(|m| m["manifest"]["id"] == id)
                .and_then(|m| {
                    array(&m["manifest"]["settings"])
                        .iter()
                        .find(|s| s["id"] == r["key"])
                })
                .ok_or("This module has no setting with that name.")?;
            modules::setting(schema, &r["value"])?;
            let mut values = settings(root, id)?;
            values[text(r, "key")] = r["value"].clone();
            if values.to_string().len() > 64 * 1024 {
                return fail("Module settings exceed 64 KB.");
            }
            write_json(&settings_path(root, id)?, &values)?;
        }
        "deleteSettings" => remove(&settings_path(root, id)?)?,
        "catalogs" => {
            return Ok(json!(catalogs(root)?
                .into_iter()
                .map(|(_, v)| v)
                .collect::<Vec<_>>()))
        }
        "addCatalog" => {
            let c = &r["catalog"];
            validate_catalog(c)?;
            let all = catalogs(root)?;
            let previous = all.iter().find(|(_, v)| v["name"] == c["name"]);
            let other: HashSet<_> = all
                .iter()
                .filter(|(_, v)| v["name"] != c["name"])
                .flat_map(|(_, v)| {
                    array(&v["packages"])
                        .iter()
                        .map(|p| text(&p["manifest"], "id"))
                })
                .collect();
            if (all.len() >= 16 && previous.is_none())
                || (previous.is_some() && !flag(r, "replaceExisting"))
                || array(&c["packages"]).iter().any(|p| {
                    array(&r["reservedIDs"])
                        .iter()
                        .any(|v| *v == p["manifest"]["id"])
                        || other.contains(text(&p["manifest"], "id"))
                })
            {
                return fail("This catalog conflicts with another catalog or bundled module.");
            }
            if let Some((path, old)) = previous {
                for p in array(&c["packages"]) {
                    if array(&old["packages"]).iter().any(|v| {
                        v["manifest"]["id"] == p["manifest"]["id"]
                            && v["manifest"]["version"].as_u64() > p["manifest"]["version"].as_u64()
                    }) {
                        return fail("A community catalog cannot downgrade module versions.");
                    }
                }
                write_json(path, c)?;
            } else {
                write_json(&root.join(format!(".catalog-{}.json", Uuid::new_v4())), c)?;
            }
        }
        "removeCatalog" => {
            for (path, c) in catalogs(root)? {
                if c["name"] == r["name"] {
                    remove(&path)?;
                }
            }
        }
        "worker" => {
            let all = inventory(root)?;
            let m = all
                .iter()
                .find(|v| v["manifest"]["id"] == id)
                .ok_or("This native worker is not installed.")?;
            if !["nativeResourceWorker", "nativeReaderWorker"]
                .contains(&text(&m["manifest"], "runtime"))
                || flag(r, "requireEnabled") && !flag(m, "enabled")
            {
                return fail("This native worker is not enabled.");
            }
            let path = root.join(id).join("worker");
            if size(&path)?.is_none_or(|n| n == 0 || n > 8 * 1024 * 1024)
                || fs::metadata(&path)
                    .map_err(|e| e.to_string())?
                    .permissions()
                    .mode()
                    & 0o111
                    == 0
            {
                return fail(
                    "This worker is missing, damaged, or not executable. Reinstall its package.",
                );
            }
            return Ok(json!(path.to_str()));
        }
        "uninstall" => {
            if !modules::id(id) {
                return fail("Invalid module ID.");
            }
            let all = inventory(root)?;
            let m = all
                .iter()
                .find(|m| m["manifest"]["id"] == id)
                .ok_or("Module is not installed.")?;
            no_dependents(id, &all)?;
            if m["manifest"]["capability"] == "tabSystem" && flag(m, "enabled") {
                return fail("Replace the active tab system before uninstalling it.");
            }
            remove(&root.join(id))?;
            if m["manifest"]["capability"] == "resourceMonitor" && flag(m, "enabled") {
                write_json(&root.join(selector("resourceMonitor")), &json!(""))?;
            }
        }
        "disableAll" => {
            for role in ROLES {
                write_json(&root.join(selector(role)), &json!(""))?;
            }
            for m in inventory(root)? {
                write_json(
                    &root.join(text(&m["manifest"], "id")).join("receipt.json"),
                    &json!({"enabled":false,"payloadSHA256":m["payloadSHA256"]}),
                )?;
            }
        }
        "seeded" => {
            let p = root.join(".initialized");
            check(&p)?;
            return Ok(json!(p.exists()));
        }
        "markSeeded" => write(&root.join(".initialized"), b"1", 0o600)?,
        _ => return fail("Unknown module repository operation."),
    }
    Ok(Value::Null)
}
