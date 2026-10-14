// SPDX-License-Identifier: MPL-2.0
//! Terminating module programs. No filesystem, network, native handles or JS.
use crate::state::{array, flag, text};
use serde_json::{json, Value};

pub fn json_bounds(data: &str) -> Result<(), &'static str> {
    let (mut depth, mut quoted, mut escaped) = (0i32, false, false);
    for b in data.bytes() {
        if quoted {
            if escaped {
                escaped = false;
            } else if b == b'\\' {
                escaped = true;
            } else if b == b'"' {
                quoted = false;
            }
        } else if b == b'"' {
            quoted = true;
        } else if b == b'{' || b == b'[' {
            depth += 1;
            if depth > 64 {
                return Err("Module JSON exceeds the nesting limit.");
            }
        } else if b == b'}' || b == b']' {
            depth -= 1;
            if depth < 0 {
                return Err("Module JSON is malformed.");
            }
        }
    }
    if depth != 0 || quoted {
        return Err("Module JSON is incomplete.");
    }
    Ok(())
}
pub fn svg_icons(icons: &Value) -> Result<(), &'static str> {
    let icons = icons
        .as_object()
        .ok_or("An icon set needs named SVG paths.")?;
    const KEYS: &[&str] = &[
        "back",
        "forward",
        "reload",
        "newTab",
        "home",
        "bookmark",
        "bookmarks",
        "history",
        "notes",
        "resources",
        "downloads",
        "modules",
        "customize",
        "settings",
        "sidebar",
        "reader",
        "screenshot",
        "focus",
        "search",
        "close",
        "grid",
        "folder",
        "user",
        "shield",
        "key",
        "split",
        "pin",
        "edit",
        "globe",
        "lock",
        "sun",
        "moon",
        "spark",
        "undo",
        "arrow",
        "grip",
        "book",
        "activity",
        "camera",
        "plug",
        "more",
        "down",
        "check",
        "external",
    ];
    if icons.is_empty()
        || icons.len() > 64
        || icons.iter().any(|(k, p)| {
            !KEYS.contains(&k.as_str()) || !p.as_str().is_some_and(crate::icons::valid_path)
        })
    {
        return Err("Icon sets accept known icons as bounded SVG path data; scripts, markup, images, and external resources are not supported.");
    }
    Ok(())
}
fn equivalent(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(a), Value::Number(b)) => a.as_f64() == b.as_f64(),
        (Value::Object(a), Value::Object(b)) => a.keys().chain(b.keys()).all(|k| {
            equivalent(
                a.get(k).unwrap_or(&Value::Null),
                b.get(k).unwrap_or(&Value::Null),
            )
        }),
        (Value::Array(a), Value::Array(b)) => {
            a.len() == b.len() && a.iter().zip(b).all(|(v, w)| equivalent(v, w))
        }
        _ => a == b,
    }
}
fn luminance(hex: &str) -> Result<f64, &'static str> {
    if !crate::appearance::hex(hex) {
        return Err("Invalid theme colors.");
    }
    let rgb = u32::from_str_radix(hex.trim_start_matches('#'), 16)
        .map_err(|_| "Invalid theme colors.")?;
    let linear = |v: u32| {
        let n = (v & 255) as f64 / 255.;
        if n <= 0.04045 {
            n / 12.92
        } else {
            ((n + 0.055) / 1.055).powf(2.4)
        }
    };
    Ok(0.2126 * linear(rgb >> 16) + 0.7152 * linear(rgb >> 8) + 0.0722 * linear(rgb))
}
pub fn definition(d: &Value, capability: &str) -> Result<(), &'static str> {
    let populated = [
        "treeTabs",
        "theme",
        "layout",
        "svgIcons",
        "icons",
        "menu",
        "widgetTitle",
    ]
    .iter()
    .filter(|k| !d[**k].is_null())
    .count();
    if d["formatVersion"] != 1 || populated != 1 {
        return Err("A declarative package must define exactly one compatible role.");
    }
    match capability {
        "tabSystem" if d["treeTabs"].is_boolean() => {}
        "theme" if d["theme"].is_object() => {
            let theme = &d["theme"];
            if theme["surfaceHex"].is_null() != theme["textHex"].is_null() {
                return Err("Custom theme surface and text colors must be supplied together.");
            }
            if !equivalent(theme, &crate::appearance::normalize_theme(theme.clone())) {
                return Err("Theme values exceed Neutrino's supported ranges.");
            }
            if !theme["surfaceHex"].is_null() {
                let a = luminance(text(theme, "surfaceHex"))?;
                let b = luminance(text(theme, "textHex"))?;
                if (a.max(b) + 0.05) / (a.min(b) + 0.05) < 4.5 {
                    return Err(
                        "Theme text must meet the 4.5:1 contrast threshold against its surface.",
                    );
                }
            }
        }
        "layout" if d["layout"].is_object() => {
            if !equivalent(
                &d["layout"],
                &crate::appearance::normalize_layout(d["layout"].clone()),
            ) {
                return Err("Layout values exceed Neutrino's supported ranges.");
            }
        }
        "icons" => {
            if !d["icons"].is_null() {
                return Err("Icon modules must supply SVG paths. Replace native symbol definitions with an SVG icon set.");
            }
            svg_icons(&d["svgIcons"])?;
        }
        "menu" => {
            let items = d["menu"].as_array().ok_or("Invalid menu items.")?;
            if items.is_empty()
                || items.len() > 16
                || items.iter().any(|i| {
                    text(i, "title").is_empty()
                        || text(i, "title").chars().count() > 80
                        || ![
                            "newTab",
                            "bookmarks",
                            "history",
                            "downloads",
                            "modules",
                            "customize",
                            "settings",
                            "recovery",
                        ]
                        .contains(&text(i, "action"))
                })
            {
                return Err("Invalid menu items.");
            }
        }
        "startWidget" => {
            if text(d, "widgetTitle").is_empty()
                || text(d, "widgetTitle").chars().count() > 100
                || d["widgetBody"]
                    .as_str()
                    .is_none_or(|v| v.chars().count() > 1000)
            {
                return Err("Invalid workspace widget.");
            }
        }
        _ => return Err("This role cannot use this declarative package."),
    }
    Ok(())
}

pub fn key(v: &str) -> bool {
    !v.is_empty()
        && v.len() <= 64
        && v.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
}
pub fn id(v: &str) -> bool {
    !v.is_empty()
        && v.len() <= 80
        && !v.starts_with('.')
        && !v.contains("..")
        && v.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b".-".contains(&b))
}
pub fn setting(s: &Value, v: &Value) -> Result<(), &'static str> {
    if !key(text(s, "id")) || text(s, "title").is_empty() || text(s, "title").chars().count() > 100
    {
        return Err("Invalid module setting.");
    }
    match text(s, "kind") {
        "toggle" => {
            if !v.is_boolean() || !s["choices"].is_null() {
                return Err("This setting needs a toggle value.");
            }
        }
        "choice" => {
            let choices = s["choices"]
                .as_array()
                .ok_or("This setting needs listed choices.")?;
            let unique: std::collections::HashSet<_> =
                choices.iter().map(Value::to_string).collect();
            if choices.is_empty()
                || choices.len() > 32
                || unique.len() != choices.len()
                || choices.iter().any(|c| {
                    c.as_str()
                        .is_none_or(|t| t.is_empty() || t.chars().count() > 100)
                })
                || !choices.contains(v)
            {
                return Err("This setting needs a listed choice.");
            }
        }
        "text" => {
            if !v.as_str().is_some_and(|t| t.chars().count() <= 1000) {
                return Err("This setting needs at most 1,000 characters.");
            }
        }
        "integer" => {
            if !v.as_u64().is_some_and(|n| n <= 200_000) {
                return Err("This number must be between 0 and 200,000.");
            }
        }
        _ => return Err("Unknown module setting kind."),
    }
    Ok(())
}
pub fn manifest(m: &Value) -> Result<(), &'static str> {
    let dependencies = m["dependencies"]
        .as_array()
        .ok_or("Invalid module dependencies.")?;
    let ids: std::collections::HashSet<_> = dependencies.iter().filter_map(Value::as_str).collect();
    if !id(text(m, "id"))
        || dependencies.len() > 32
        || ids.len() != dependencies.len()
        || ids.iter().any(|v| !id(v))
        || ids.contains(text(m, "id"))
    {
        return Err("Invalid module ID or dependencies.");
    }
    let source = url::Url::parse(text(m, "source")).map_err(|_| "Invalid module source.")?;
    if m["version"].as_u64().unwrap_or(0) == 0
        || text(m, "name").is_empty()
        || text(m, "name").chars().count() > 100
        || text(m, "summary").chars().count() > 1000
        || text(m, "publisher").chars().count() > 100
        || source.scheme() != "https"
        || source.host_str().is_none()
        || !source.username().is_empty()
        || source.password().is_some()
    {
        return Err("The module manifest contains invalid metadata.");
    }
    if !m["minimumHostVersion"].is_null() && m["minimumHostVersion"] != 1 {
        return Err("This module requires a newer Neutrino version.");
    }
    if m["dependencyVersions"].as_object().is_some_and(|o| {
        o.iter().any(|(k, v)| {
            !ids.contains(k.as_str()) || !v.as_u64().is_some_and(|n| (1..=100_000).contains(&n))
        })
    }) {
        return Err("Dependency version requirements are invalid.");
    }
    let settings = m["settings"].as_array().map(Vec::as_slice).unwrap_or(&[]);
    let keys: std::collections::HashSet<_> = settings.iter().map(|s| text(s, "id")).collect();
    if settings.len() > 16 || keys.len() != settings.len() {
        return Err("Module settings are invalid.");
    }
    for s in settings {
        setting(s, &s["defaultValue"])?;
    }
    let capability = text(m, "capability");
    let runtime = text(m, "runtime");
    if !runtime.is_empty()
        && !match runtime {
            "nativeResourceWorker" => capability == "resourceMonitor",
            "nativeReaderWorker" => capability == "reader",
            "behaviorProgram" => ["notes", "screenshot", "focusMode"].contains(&capability),
            "declarative" => [
                "tabSystem",
                "theme",
                "layout",
                "icons",
                "menu",
                "startWidget",
            ]
            .contains(&capability),
            _ => false,
        }
    {
        return Err("This module role and runtime are incompatible.");
    }
    if m.to_string().len() > 32 * 1024 {
        return Err("Module manifest exceeds 32 KB.");
    }
    Ok(())
}
pub fn plan(
    root: &str,
    catalog: &Value,
    installed: &Value,
    include: bool,
) -> Result<Value, &'static str> {
    let catalog = catalog.as_array().ok_or("Invalid module catalog.")?;
    let existing = installed
        .as_array()
        .ok_or("Invalid installed module inventory.")?;
    if catalog.len() > 512 || existing.len() > 512 {
        return Err("The module inventory exceeds its size limit.");
    }
    let mut index = std::collections::HashMap::new();
    for m in catalog {
        manifest(m)?;
        if index.insert(text(m, "id"), m).is_some() {
            return Err("Catalog contains duplicate module IDs.");
        }
    }
    fn visit<'a>(
        current: &'a str,
        index: &std::collections::HashMap<&'a str, &'a Value>,
        existing: &'a [Value],
        include: bool,
        visiting: &mut std::collections::HashSet<&'a str>,
        visited: &mut std::collections::HashSet<&'a str>,
        out: &mut Vec<Value>,
    ) -> Result<(), &'static str> {
        if visited.contains(current) {
            return Ok(());
        }
        if visiting.len() > 64 || !visiting.insert(current) {
            return Err("Modules have circular dependencies or exceed the dependency depth limit.");
        }
        let available = index.get(current).copied();
        let installed = existing
            .iter()
            .find(|e| text(&e["manifest"], "id") == current)
            .map(|e| &e["manifest"]);
        let m = match (available, installed) {
            (Some(a), Some(i)) => {
                if i["version"].as_u64() >= a["version"].as_u64() {
                    i
                } else {
                    a
                }
            }
            (Some(a), None) => a,
            (None, Some(i)) => i,
            _ => return Err("A required module is missing."),
        };
        manifest(m)?;
        for d in m["dependencies"].as_array().unwrap() {
            let d = d.as_str().unwrap();
            let version = index
                .get(d)
                .and_then(|m| m["version"].as_u64())
                .unwrap_or(0)
                .max(
                    existing
                        .iter()
                        .find(|e| text(&e["manifest"], "id") == d)
                        .and_then(|e| e["manifest"]["version"].as_u64())
                        .unwrap_or(0),
                );
            if version < m["dependencyVersions"][d].as_u64().unwrap_or(1) {
                return Err("A required module dependency is too old.");
            }
            visit(d, index, existing, include, visiting, visited, out)?;
        }
        visiting.remove(current);
        visited.insert(current);
        if include
            || !existing.iter().any(|e| {
                text(&e["manifest"], "id") == current
                    && e["manifest"]["version"].as_u64() >= m["version"].as_u64()
                    && e["enabled"] == true
            })
        {
            out.push(m.clone());
        }
        Ok(())
    }
    let mut out = vec![];
    visit(
        root,
        &index,
        existing,
        include,
        &mut std::collections::HashSet::new(),
        &mut std::collections::HashSet::new(),
        &mut out,
    )?;
    Ok(json!(out))
}
pub fn value(v: &Value, depth: usize) -> Result<(), &'static str> {
    if depth > 16 {
        return Err("Module data is nested too deeply.");
    }
    match v {
        Value::String(s) if s.len() > 1_000_000 => return Err("Module text is too large."),
        Value::Number(n) if n.as_i64().is_none() => {
            return Err("Module numbers must be bounded integers.")
        }
        Value::Array(a) => {
            if a.len() > 64 {
                return Err("Module arrays are too large.");
            }
            for v in a {
                value(v, depth + 1)?;
            }
        }
        Value::Object(o) => {
            if o.len() > 64 || o.keys().any(|k| !key(k)) {
                return Err("Module fields are invalid.");
            }
            for v in o.values() {
                value(v, depth + 1)?;
            }
        }
        _ => {}
    }
    Ok(())
}
fn expression(e: &Value, depth: usize, budget: &mut usize) -> Result<(), &'static str> {
    if depth > 16 || *budget == 0 {
        return Err("Module programs exceed the instruction limit.");
    }
    *budget -= 1;
    let op = text(e, "op");
    let expected = match op {
        "prefix" => 1,
        "equal" => 2,
        "choose" => 3,
        "literal" | "input" | "object" => 0,
        _ => return Err("Unknown module instruction."),
    };
    let arguments = e["arguments"].as_array();
    if arguments.map_or(0, Vec::len) != expected {
        return Err("A module instruction has invalid arguments.");
    }
    match op {
        "literal" => value(e.get("value").ok_or("A literal needs a value.")?, 0)?,
        "input" => {
            if !key(text(e, "key")) {
                return Err("A module input name is invalid.");
            }
        }
        "prefix" => {
            if !e["limit"].as_u64().is_some_and(|n| n <= 200_000) {
                return Err("A text limit is invalid.");
            }
        }
        "object" => {
            let fields = e["fields"]
                .as_object()
                .ok_or("Module output fields are invalid.")?;
            if fields.len() > 32 || fields.keys().any(|k| !key(k)) {
                return Err("Module output fields are invalid.");
            }
        }
        _ => {}
    }
    for (field, owner) in [
        ("value", "literal"),
        ("key", "input"),
        ("limit", "prefix"),
        ("fields", "object"),
    ] {
        if op != owner && !e[field].is_null() {
            return Err("A module instruction contains unsupported properties.");
        }
    }
    for a in arguments.into_iter().flatten() {
        expression(a, depth + 1, budget)?;
    }
    for f in e["fields"].as_object().into_iter().flat_map(|o| o.values()) {
        expression(f, depth + 1, budget)?;
    }
    Ok(())
}
pub fn validate(program: &Value, capability: &str) -> Result<(), &'static str> {
    let entries = program["entrypoints"]
        .as_object()
        .ok_or("This behavior program is incompatible with Neutrino.")?;
    if program["formatVersion"] != 1
        || entries.is_empty()
        || entries.len() > 16
        || entries.keys().any(|k| !key(k))
    {
        return Err("This behavior program is incompatible with Neutrino.");
    }
    let mut budget = 512;
    for e in entries.values() {
        expression(e, 0, &mut budget)?;
    }
    let required: &[&str] = match capability {
        "" => &[],
        "notes" => &["create", "update", "delete"],
        "screenshot" => &["prepare"],
        "focusMode" => &["enter", "exit"],
        _ => return Err("This role does not support a behavior program."),
    };
    if required.iter().any(|k| !entries.contains_key(*k)) {
        return Err(
            "This behavior package does not implement every required operation for its role.",
        );
    }
    Ok(())
}
fn evaluate(e: &Value, input: &Value) -> Result<Value, &'static str> {
    let args = e["arguments"].as_array().map(Vec::as_slice).unwrap_or(&[]);
    Ok(match text(e, "op") {
        "literal" => e["value"].clone(),
        "input" => input[text(e, "key")].clone(),
        "prefix" => json!(evaluate(&args[0], input)?
            .as_str()
            .ok_or("This module expected text.")?
            .chars()
            .take(e["limit"].as_u64().unwrap() as usize)
            .collect::<String>()),
        "equal" => json!(evaluate(&args[0], input)? == evaluate(&args[1], input)?),
        "choose" => evaluate(
            &args[if evaluate(&args[0], input)?
                .as_bool()
                .ok_or("This module expected a condition.")?
            {
                1
            } else {
                2
            }],
            input,
        )?,
        "object" => Value::Object(
            e["fields"]
                .as_object()
                .unwrap()
                .iter()
                .map(|(k, e)| Ok((k.clone(), evaluate(e, input)?)))
                .collect::<Result<_, &'static str>>()?,
        ),
        _ => return Err("Unknown module instruction."),
    })
}
pub fn run(program: &Value, event: &str, input: &Value) -> Result<Value, &'static str> {
    validate(program, "")?;
    value(input, 0)?;
    if !input.is_object() || input.to_string().len() > 1_048_576 {
        return Err("Module input exceeds 1 MB or is not named values.");
    }
    let expression = program["entrypoints"]
        .get(event)
        .ok_or("This module does not implement the requested event.")?;
    let output = evaluate(expression, input)?;
    if !output.is_object() {
        return Err("A module must return named values.");
    }
    value(&output, 0)?;
    if output.to_string().len() > 1_048_576 {
        return Err("Module output exceeds 1 MB.");
    }
    Ok(output)
}

/// Whole-setup dependency/replacement policy, shared by every platform host.
pub fn requirements(r: &Value, installed: &Value) -> Result<Value, String> {
    let ids = r["ids"].as_array().ok_or("Invalid module requirements.")?;
    if ids.len() > 64 {
        return Err("Too many module requirements.".into());
    }
    let mut result = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let mut roles = std::collections::HashMap::new();
    let existing = array(installed);
    for id in ids {
        let id = id.as_str().ok_or("Invalid module requirement.")?;
        let planned = plan(id, &r["catalog"], installed, true).map_err(String::from)?;
        for m in array(&planned) {
            if !seen.insert(text(m, "id").to_owned()) {
                continue;
            }
            let role = text(m, "capability");
            if [
                "resourceMonitor",
                "notes",
                "screenshot",
                "focusMode",
                "tabSystem",
                "theme",
                "layout",
                "icons",
                "menu",
            ]
            .contains(&role)
            {
                if roles
                    .insert(role.to_owned(), text(m, "id").to_owned())
                    .is_some_and(|v| v != text(m, "id"))
                {
                    return Err(format!("These requirements choose multiple providers for {role}. Choose one before applying the setup."));
                }
            }
            if let Some(old) = existing.iter().find(|v| v["manifest"]["id"] == m["id"]) {
                if old["manifest"]["capability"] != m["capability"]
                    || (!old["manifest"]["runtime"].is_null()
                        && old["manifest"]["runtime"] != m["runtime"])
                {
                    return Err("A package update cannot change its module role or runtime. Import it with a new module ID instead.".into());
                }
            }
            result.push(m.clone());
        }
    }
    if !flag(r, "preparingActivation") {
        for m in result.iter().filter(|m| {
            existing
                .iter()
                .any(|v| flag(v, "enabled") && v["manifest"]["id"] == m["id"])
        }) {
            if !array(&m["dependencies"]).iter().all(|d| {
                existing
                    .iter()
                    .any(|v| flag(v, "enabled") && v["manifest"]["id"] == *d)
                    && result
                        .iter()
                        .find(|v| v["id"] == *d)
                        .and_then(|v| v["version"].as_u64())
                        .unwrap_or(0)
                        >= m["dependencyVersions"][d.as_str().unwrap_or("")]
                            .as_u64()
                            .unwrap_or(1)
            }) {
                return Err(format!("Update {} separately first. Updating this disabled module must not disable or replace an active dependency.",text(m,"name")));
            }
        }
    }
    for active in existing.iter().filter(|v| flag(v, "enabled")) {
        let Some(next) = roles.get(text(&active["manifest"], "capability")) else {
            continue;
        };
        if *next == text(&active["manifest"], "id")
            || !flag(r, "preparingActivation")
            || (!flag(r, "replacingRootProviders") && ids.iter().any(|id| id == next))
        {
            continue;
        }
        for dependent in existing.iter().filter(|v| {
            flag(v, "enabled")
                && array(&v["manifest"]["dependencies"]).contains(&active["manifest"]["id"])
        }) {
            if result
                .iter()
                .find(|v| v["id"] == dependent["manifest"]["id"])
                .is_none_or(|v| array(&v["dependencies"]).contains(&active["manifest"]["id"]))
            {
                return Err(format!(
                    "Disable {} before replacing {}.",
                    text(&dependent["manifest"], "name"),
                    text(&active["manifest"], "name")
                ));
            }
        }
    }
    Ok(json!(result))
}
