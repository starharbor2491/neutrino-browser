// SPDX-License-Identifier: MPL-2.0
//! Portable external-data policy. macOS adapters supply platform facts and effects.
use crate::state::{array, text};
use serde_json::{json, Value};
use url::Url;
fn finite(v: &Value) -> Option<f64> {
    v.as_f64().filter(|v| v.is_finite())
}
fn macos(minimum: &str, actual: &Value) -> Result<(), String> {
    let parts: Vec<_> = minimum.split('.').collect();
    let numbers: Option<Vec<u16>> = parts
        .iter()
        .map(|p| {
            if !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()) {
                p.parse().ok().filter(|v| *v <= 999)
            } else {
                None
            }
        })
        .collect();
    let n = numbers
        .filter(|v| (2..=3).contains(&v.len()) && v[0] > 0)
        .ok_or("The release has an invalid macOS compatibility requirement.")?;
    if actual.is_array()
        && (
            actual[0].as_u64().unwrap_or(0),
            actual[1].as_u64().unwrap_or(0),
            actual[2].as_u64().unwrap_or(0),
        ) < (n[0] as u64, n[1] as u64, *n.get(2).unwrap_or(&0) as u64)
    {
        return Err(format!("This release requires macOS {minimum} or later. Your installed application has been kept."));
    }
    Ok(())
}
fn release(v: &Value, r: &Value) -> Result<(), String> {
    macos(v["minimumMacOS"].as_str().unwrap_or("14.0"), &r["system"])?;
    let version = text(v, "version");
    if v["format"] != 1
        || v["build"].as_u64().unwrap_or(0) == 0
        || version.is_empty()
        || version.len() > 64
        || !version
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b".-+".contains(&b))
        || v["securityEpoch"].as_u64().is_none()
        || !(v["architecture"] == r["architecture"] || v["architecture"] == "universal")
    {
        return Err("This release is incompatible with this Mac.".into());
    }
    if v["build"].as_u64().unwrap_or(0) < r["current"]["build"].as_u64().unwrap_or(0)
        || v["securityEpoch"].as_u64().unwrap_or(0)
            < r["current"]["securityEpoch"]
                .as_u64()
                .unwrap_or(0)
                .max(r["minimumEpoch"].as_u64().unwrap_or(0))
    {
        return Err("Neutrino will not install an older application or an engine below the accepted security version.".into());
    }
    Ok(())
}
fn asset(v: &Value) -> Result<(), String> {
    let valid = Url::parse(text(v, "url")).is_ok_and(|u| {
        u.scheme() == "https"
            && u.host_str() == Some("github.com")
            && u.username().is_empty()
            && u.password().is_none()
            && u.path()
                .starts_with("/starharbor2491/neutrino-browser/releases/download/")
            && u.path().ends_with(".dmg")
            && u.query().is_none()
            && u.fragment().is_none()
    });
    let hex = |s: &str, n| {
        s.len() == n
            && s.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    };
    if !valid
        || !v["bytes"]
            .as_u64()
            .is_some_and(|v| (1..=4_000_000_000).contains(&v))
        || !hex(text(v, "sha256"), 64)
    {
        return Err("The release catalog contains an invalid asset.".into());
    }
    if !v["codeDirectoryHash"].is_null() && !hex(text(v, "codeDirectoryHash"), 40) {
        return Err("The release catalog contains an invalid application code hash.".into());
    }
    Ok(())
}
fn dispatch(r: &Value) -> Result<Value, String> {
    let v = &r["value"];
    match text(r, "op") {
        "validateMinimumMacOS" => macos(text(r, "minimum"), &r["system"])?,
        "validateRelease" => release(v, r)?,
        "validateDistributionAsset" => asset(v)?,
        "validateDistributionCatalog" => {
            if v["format"] != 1 || array(&v["releases"]).len() > 16 {
                return Err("The release catalog is incompatible or too large.".into());
            }
            for a in array(&v["releases"]) {
                asset(a)?;
            }
        }
        "distributionUpdates" => {
            let mut assets: Vec<_> = array(&v["releases"])
                .iter()
                .filter(|a| {
                    a["release"]["build"].as_u64().unwrap_or(0)
                        > r["current"]["build"].as_u64().unwrap_or(0)
                        && a["release"]["chromium"] == r["current"]["chromium"]
                        && release(&a["release"], r).is_ok()
                })
                .cloned()
                .collect();
            assets.sort_by_key(|a| std::cmp::Reverse(a["release"]["build"].as_u64().unwrap_or(0)));
            return Ok(json!(assets));
        }
        "validateEngineManifest" => {
            let major = text(v, "cefVersion")
                .split('.')
                .next()
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(0);
            if v["format"] != 2
                || !v["abi"].as_u64().is_some_and(|v| (1..=1024).contains(&v))
                || v["runtimeStyle"] != "chromeViews"
                || !["arm64", "x86_64"].contains(&text(v, "architecture"))
                || v["architecture"] != r["release"]["architecture"]
                || (!r["architecture"].is_null() && v["architecture"] != r["architecture"])
                || r["release"]["chromium"] != true
                || text(v, "cefVersion").is_empty()
                || text(v, "cefVersion").chars().count() > 256
                || major == 0
                || r["release"]["securityEpoch"].as_u64().unwrap_or(0) < major
            {
                return Err(
                    "The Chromium package has an incompatible architecture or security version."
                        .into(),
                );
            }
        }
        "validateIdentity" => {
            let aud = if let Some(v) = v["aud"].as_str() {
                vec![json!(v)]
            } else {
                array(&v["aud"]).to_vec()
            };
            let time = finite(&r["now"]).ok_or("Invalid identity validation time.")?;
            let exp = finite(&v["exp"]).unwrap_or(0.);
            let iat = finite(&v["iat"]).unwrap_or(0.);
            if v["iss"] != r["issuer"]
                || text(v, "sub").is_empty()
                || text(v, "sub").len() > 256
                || (!r["subject"].is_null() && v["sub"] != r["subject"])
                || aud.is_empty()
                || aud.len() > 20
                || !aud.iter().any(|v| *v == r["clientID"])
                || !((aud.len() == 1 && v["azp"].is_null()) || v["azp"] == r["clientID"])
                || (!r["nonce"].is_null() && v["nonce"] != r["nonce"])
                || exp <= time
                || iat <= 0.
                || iat > time + 60.
                || exp <= iat
                || (!v["nbf"].is_null() && finite(&v["nbf"]).is_none_or(|v| v > time + 60.))
            {
                return Err("The account identity claims do not match this authorization.".into());
            }
        }
        "validateResourceFrame" => {
            let short = |v: &Value, key: &str, n| text(v, key).chars().count() <= n;
            let unit = |v: &Value| finite(v).is_some_and(|v| (0.0..=1.0).contains(&v));
            if !short(v, "title", 100)
                || !short(v, "detail", 1000)
                || array(&v["metrics"]).len() > 12
                || array(&v["metrics"]).iter().any(|m| {
                    !short(m, "name", 100)
                        || !short(m, "value", 100)
                        || !short(m, "detail", 500)
                        || (!m["fraction"].is_null() && !unit(&m["fraction"]))
                        || array(&m["samples"]).len() > 60
                        || array(&m["samples"]).iter().any(|s| !unit(s))
                })
            {
                return Err("The resource worker returned an invalid display.".into());
            }
        }
        "normalizeSetupPack" => {
            if v["formatVersion"] != 1 {
                return Err("This setup pack needs a newer Neutrino version.".into());
            }
            let name = text(v, "name");
            if name.trim().is_empty() || name.chars().count() > 100 {
                return Err("Use a setup name of 1–100 characters.".into());
            }
            let requirements = array(&v["requiredModuleIDs"]);
            if requirements.len() > 32
                || requirements
                    .iter()
                    .any(|v| !v.as_str().is_some_and(crate::modules::id))
                || requirements
                    .iter()
                    .collect::<std::collections::HashSet<_>>()
                    .len()
                    != requirements.len()
            {
                return Err("Setup module requirements are invalid.".into());
            }
            let mut v = v.clone();
            v["configuration"]["theme"] =
                crate::appearance::normalize_theme(v["configuration"]["theme"].clone());
            v["configuration"]["layout"] =
                crate::appearance::normalize_layout(v["configuration"]["layout"].clone());
            return Ok(v);
        }
        "boundedImport" => return bounded_import(r),
        _ => return Err("Unknown data policy operation.".into()),
    }
    Ok(json!(true))
}
fn bounded_import(r: &Value) -> Result<Value, String> {
    use base64::Engine;
    use std::io::Read;
    let kind = match text(r, "kind") {
        "bookmarks" => "bookmarks HTML",
        "setup" => "setup JSON",
        "module" => "module",
        _ => return Err("Unknown import kind.".into()),
    };
    let limit = r["maximumBytes"]
        .as_u64()
        .filter(|v| *v > 0 && *v <= 64 * 1024 * 1024)
        .ok_or(format!("Choose a local {kind} file within its size limit."))?;
    let path = std::path::Path::new(text(r, "path"));
    if !path.is_absolute() {
        return Err(format!("Choose a local {kind} file within its size limit."));
    }
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC);
    }
    let file = options.open(path).map_err(|_| {
        format!("Choose a readable, regular {kind} file. Symbolic links are not supported.")
    })?;
    let info = file.metadata().map_err(|e| e.to_string())?;
    if !info.is_file() {
        return Err(format!(
            "Choose a regular {kind} file. Folders and streams are not supported."
        ));
    }
    let size = if limit % (1024 * 1024) == 0 {
        format!("{} MB", limit / (1024 * 1024))
    } else if limit % 1024 == 0 {
        format!("{} KB", limit / 1024)
    } else {
        format!("{limit} bytes")
    };
    let too_large = format!("The {kind} file must contain at most {size}.");
    if info.len() > limit {
        return Err(too_large);
    }
    let mut bytes = Vec::new();
    file.take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() as u64 > limit {
        return Err(too_large);
    }
    Ok(json!(
        base64::engine::general_purpose::STANDARD.encode(bytes)
    ))
}
pub fn request(r: &Value) -> Value {
    match dispatch(r) {
        Ok(v) => json!({"result":v}),
        Err(e) => json!({"error":e}),
    }
}
