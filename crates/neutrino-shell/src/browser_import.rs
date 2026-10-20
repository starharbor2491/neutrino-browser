// SPDX-License-Identifier: MPL-2.0
//! Reads bookmarks and history other browsers keep on this Mac. Chromium-family
//! browsers share one JSON bookmarks format and one SQLite history format; Firefox
//! and Safari keep SQLite databases. Safari's bookmarks are read by the host.
use crate::state::array;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

const MAX_BOOKMARKS: usize = 20_000;
const MAX_FILE_BYTES: u64 = 64 * 1024 * 1024;

/// A Chromium-family browser's data folder, under ~/Library.
fn chromium_root(source: &str) -> Option<&'static str> {
    Some(match source {
        "chrome" => "Library/Application Support/Google/Chrome",
        "edge" => "Library/Application Support/Microsoft Edge",
        "brave" => "Library/Application Support/BraveSoftware/Brave-Browser",
        "arc" => "Library/Application Support/Arc/User Data",
        "vivaldi" => "Library/Application Support/Vivaldi",
        "opera" => "Library/Application Support/com.operasoftware.Opera",
        "operagx" => "Library/Application Support/com.operasoftware.OperaGX",
        _ => return None,
    })
}

/// The profile folder the browser last used, from its `Local State`, or `Default`.
/// Opera keeps its one profile at the top of its folder.
fn chromium_profile(source: &str, home: &Path) -> Option<PathBuf> {
    let root = home.join(chromium_root(source)?);
    if source == "opera" || source == "operagx" {
        return Some(root);
    }
    let last = std::fs::metadata(root.join("Local State"))
        .ok()
        .filter(|m| m.len() <= 8 * 1024 * 1024)
        .and_then(|_| std::fs::read(root.join("Local State")).ok())
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|state| state["profile"]["last_used"].as_str().map(str::to_string));
    let name = last
        .filter(|n| !n.is_empty() && n.len() <= 64 && !n.contains(['/', '\\']) && n != "." && n != ".." && root.join(n).is_dir())
        .unwrap_or_else(|| "Default".into());
    Some(root.join(name))
}

fn web(url: &str) -> bool {
    url.starts_with("https://") || url.starts_with("http://")
}

/// Flattens a Chromium `Bookmarks` document into title/address pairs.
pub fn parse_chromium(document: &Value) -> Vec<Value> {
    fn walk(node: &Value, out: &mut Vec<Value>) {
        if out.len() >= MAX_BOOKMARKS {
            return;
        }
        if node["type"] == "url" {
            let url = node["url"].as_str().unwrap_or("");
            if web(url) && url.len() <= 8192 {
                out.push(json!({"title": node["name"].as_str().unwrap_or("").chars().take(512).collect::<String>(), "url": url}));
            }
        }
        for child in node["children"].as_array().into_iter().flatten() {
            walk(child, out);
        }
    }
    let mut out = vec![];
    for root in document["roots"].as_object().into_iter().flat_map(|r| r.values()) {
        walk(root, &mut out);
    }
    out
}

fn read_bounded(path: &Path) -> Result<Vec<u8>, &'static str> {
    let size = std::fs::metadata(path).map_err(|_| "That browser’s bookmarks weren’t found on this Mac.")?.len();
    if size > MAX_FILE_BYTES {
        return Err("That browser’s bookmarks file is too large to import.");
    }
    std::fs::read(path).map_err(|_| "That browser’s bookmarks couldn’t be read.")
}

/// The most recently used Firefox profile that has a bookmarks database.
fn firefox_places(home: &Path) -> Option<PathBuf> {
    let profiles = home.join("Library/Application Support/Firefox/Profiles");
    std::fs::read_dir(profiles)
        .ok()?
        .flatten()
        .map(|entry| entry.path().join("places.sqlite"))
        .filter(|places| places.is_file())
        .max_by_key(|places| std::fs::metadata(places).and_then(|m| m.modified()).ok())
}

fn parse_firefox(places: &Path) -> Result<Vec<Value>, &'static str> {
    // Firefox locks its database while running; read a private copy instead.
    let copy = std::env::temp_dir().join(format!("neutrino-places-{}.sqlite", std::process::id()));
    std::fs::write(&copy, read_bounded(places)?).map_err(|_| "Firefox bookmarks couldn’t be copied for import.")?;
    let result = (|| {
        let db = rusqlite::Connection::open_with_flags(&copy, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .map_err(|_| "Firefox bookmarks couldn’t be opened.")?;
        let mut query = db
            .prepare("SELECT COALESCE(b.title, ''), p.url FROM moz_bookmarks b JOIN moz_places p ON b.fk = p.id WHERE b.type = 1 LIMIT ?1")
            .map_err(|_| "This Firefox profile uses an unsupported format.")?;
        let rows = query
            .query_map([MAX_BOOKMARKS as i64], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))
            .map_err(|_| "Firefox bookmarks couldn’t be read.")?;
        Ok(rows
            .flatten()
            .filter(|(_, url)| web(url) && url.len() <= 8192)
            .map(|(title, url)| json!({"title": title.chars().take(512).collect::<String>(), "url": url}))
            .collect())
    })();
    let _ = std::fs::remove_file(&copy);
    result
}

/// Seconds between 1970-01-01 and 2001-01-01, the host's date reference.
const REFERENCE: f64 = 978_307_200.0;

/// Runs a read-only query on a private copy of a database another browser may hold open.
fn query_copy(path: &Path, sql: &str, row: fn(&rusqlite::Row) -> rusqlite::Result<(String, String, f64)>) -> Result<Vec<Value>, &'static str> {
    let copy = std::env::temp_dir().join(format!("neutrino-history-{}.sqlite", std::process::id()));
    std::fs::write(&copy, read_bounded(path)?).map_err(|_| "That browser’s history couldn’t be copied for import.")?;
    let result = (|| {
        let db = rusqlite::Connection::open_with_flags(&copy, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .map_err(|_| "That browser’s history couldn’t be opened.")?;
        let mut query = db.prepare(sql).map_err(|_| "That browser’s history uses an unsupported format.")?;
        let rows = query.query_map([], row).map_err(|_| "That browser’s history couldn’t be read.")?;
        Ok(rows
            .flatten()
            .filter(|(url, _, at)| web(url) && url.len() <= 8192 && at.is_finite())
            .map(|(url, title, at)| json!({"title": title.chars().take(512).collect::<String>(), "url": url, "visitedAt": at}))
            .collect())
    })();
    let _ = std::fs::remove_file(&copy);
    result
}

/// Recent history of another browser on this Mac, newest first, as
/// `[{title, url, visitedAt}]` with seconds since 2001-01-01.
pub fn history(source: &str, home: &str) -> Result<Value, &'static str> {
    let home = Path::new(home);
    if !home.is_absolute() {
        return Err("Invalid home folder.");
    }
    let found = match source {
        "firefox" => {
            let places = firefox_places(home).ok_or("Firefox history wasn’t found on this Mac.")?;
            query_copy(&places, "SELECT url, COALESCE(title, ''), last_visit_date FROM moz_places WHERE last_visit_date IS NOT NULL ORDER BY last_visit_date DESC LIMIT 5000",
                |r| Ok((r.get(0)?, r.get(1)?, r.get::<_, i64>(2)? as f64 / 1e6 - REFERENCE)))?
        }
        "safari" => query_copy(&home.join("Library/Safari/History.db"),
            "SELECT i.url, COALESCE(v.title, ''), v.visit_time FROM history_visits v JOIN history_items i ON v.history_item = i.id ORDER BY v.visit_time DESC LIMIT 5000",
            |r| Ok((r.get(0)?, r.get(1)?, r.get::<_, f64>(2)?)))
            .map_err(|_| "macOS protects Safari’s history. Allow Neutrino in System Settings → Privacy & Security → Full Disk Access, then import again.")?,
        _ => {
            let history = chromium_profile(source, home).ok_or("Importing from that browser isn’t supported.")?.join("History");
            // Chromium counts microseconds from 1601-01-01.
            query_copy(&history, "SELECT url, COALESCE(title, ''), last_visit_time FROM urls WHERE last_visit_time > 0 ORDER BY last_visit_time DESC LIMIT 5000",
                |r| Ok((r.get(0)?, r.get(1)?, r.get::<_, i64>(2)? as f64 / 1e6 - 11_644_473_600.0 - REFERENCE)))?
        }
    };
    Ok(json!(found))
}

/// Bookmarks of another browser on this Mac, as `[{title, url}]`.
pub fn bookmarks(source: &str, home: &str) -> Result<Value, &'static str> {
    let home = Path::new(home);
    if !home.is_absolute() {
        return Err("Invalid home folder.");
    }
    if source == "firefox" {
        let places = firefox_places(home).ok_or("Firefox bookmarks weren’t found on this Mac.")?;
        return Ok(json!(parse_firefox(&places)?));
    }
    let profile = chromium_profile(source, home).ok_or("Importing from that browser isn’t supported.")?;
    let document: Value = serde_json::from_slice(&read_bounded(&profile.join("Bookmarks"))?)
        .map_err(|_| "That browser’s bookmarks file couldn’t be read.")?;
    Ok(json!(parse_chromium(&document)))
}

/// Saved logins of a Chromium-family browser: `[{origin, username, encrypted}]`, where
/// `encrypted` is the stored value in base64. Only the host can decrypt it, with the
/// browser's key from Keychain, so passwords never pass through here in plain text.
pub fn logins(source: &str, home: &str) -> Result<Value, &'static str> {
    use base64::Engine;
    let home = Path::new(home);
    if !home.is_absolute() {
        return Err("Invalid home folder.");
    }
    let path = chromium_profile(source, home).ok_or("Importing passwords from that browser isn’t supported.")?.join("Login Data");
    let copy = std::env::temp_dir().join(format!("neutrino-logins-{}.sqlite", std::process::id()));
    std::fs::write(&copy, read_bounded(&path).map_err(|_| "That browser’s saved passwords weren’t found on this Mac.")?)
        .map_err(|_| "That browser’s saved passwords couldn’t be copied for import.")?;
    let result = (|| {
        let db = rusqlite::Connection::open_with_flags(&copy, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .map_err(|_| "That browser’s saved passwords couldn’t be opened.")?;
        let mut query = db
            .prepare("SELECT origin_url, username_value, password_value FROM logins LIMIT 5000")
            .map_err(|_| "That browser’s saved passwords use an unsupported format.")?;
        let rows = query
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, Vec<u8>>(2)?)))
            .map_err(|_| "That browser’s saved passwords couldn’t be read.")?;
        Ok(rows
            .flatten()
            .filter(|(origin, username, secret)| web(origin) && origin.len() <= 2048 && username.len() <= 500 && !secret.is_empty() && secret.len() <= 16_384)
            .map(|(origin, username, secret)| json!({"origin": origin, "username": username, "encrypted": base64::engine::general_purpose::STANDARD.encode(secret)}))
            .collect::<Vec<_>>())
    })();
    let _ = std::fs::remove_file(&copy);
    result.map(|found| json!(found))
}

/// One DER element: its tag, its contents and what follows it.
fn der(input: &[u8]) -> Option<(u8, &[u8], &[u8])> {
    let (&tag, rest) = input.split_first()?;
    let (&first, rest) = rest.split_first()?;
    let (length, rest) = if first < 0x80 {
        (first as usize, rest)
    } else {
        let count = (first & 0x7f) as usize;
        if count == 0 || count > 3 || rest.len() < count {
            return None;
        }
        (rest[..count].iter().fold(0usize, |n, b| n << 8 | *b as usize), &rest[count..])
    };
    (rest.len() >= length).then(|| (tag, &rest[..length], &rest[length..]))
}
/// The elements in a run of DER: a sequence's contents.
fn der_children(mut body: &[u8]) -> Option<Vec<(u8, &[u8])>> {
    let mut out = vec![];
    while !body.is_empty() {
        let (tag, value, rest) = der(body)?;
        out.push((tag, value));
        body = rest;
    }
    Some(out)
}
/// The elements inside an encoded DER sequence.
fn der_items(sequence: &[u8]) -> Option<Vec<(u8, &[u8])>> {
    let (tag, body, _) = der(sequence)?;
    if tag != 0x30 {
        return None;
    }
    der_children(body)
}
const OID_PBES2: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0d];
const OID_PBKDF2: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0c];
const OID_AES256_CBC: &[u8] = &[0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2a];
const OID_DES3_CBC: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x03, 0x07];

/// A key4.db item NSS encrypted with PBES2 (PBKDF2-HMAC-SHA256, AES-256-CBC):
/// `{salt, iterations, iv, data}` in base64, for the host to decrypt.
fn firefox_pbes2(item: &[u8]) -> Option<Value> {
    use base64::Engine;
    let b64 = |v: &[u8]| base64::engine::general_purpose::STANDARD.encode(v);
    let top = der_items(item)?;
    let ((0x30, algorithm), (0x04, data)) = (top.first()?.clone(), top.get(1)?.clone()) else { return None };
    let algorithm = der_children(algorithm)?;
    let ((0x06, OID_PBES2), (0x30, params)) = (algorithm.first()?.clone(), algorithm.get(1)?.clone()) else { return None };
    let params = der_children(params)?;
    let kdf = der_children(params.first()?.1)?;
    let cipher = der_children(params.get(1)?.1)?;
    let ((0x06, OID_PBKDF2), (0x30, kdf_params)) = (kdf.first()?.clone(), kdf.get(1)?.clone()) else { return None };
    let kdf_params = der_children(kdf_params)?;
    let ((0x04, salt), (0x02, iterations)) = (kdf_params.first()?.clone(), kdf_params.get(1)?.clone()) else { return None };
    let ((0x06, OID_AES256_CBC), (0x04, iv)) = (cipher.first()?.clone(), cipher.get(1)?.clone()) else { return None };
    let iterations = iterations.iter().fold(0u64, |n, b| n << 8 | *b as u64);
    // NSS keeps 14 bytes; the IV is that octet string's whole encoding, 04 0E and the bytes.
    let iv: Vec<u8> = match iv.len() { 14 => [&[0x04, 0x0e][..], iv].concat(), 16 => iv.to_vec(), _ => return None };
    (iterations > 0 && iterations <= 10_000_000 && !data.is_empty() && data.len() % 16 == 0)
        .then(|| json!({"salt": b64(salt), "iterations": iterations, "iv": b64(&iv), "data": b64(data)}))
}
/// One encrypted login field from logins.json: `{cipher: "des3"|"aes", iv, data}`.
fn firefox_field(encoded: &str) -> Option<Value> {
    use base64::Engine;
    let b64 = |v: &[u8]| base64::engine::general_purpose::STANDARD.encode(v);
    let raw = base64::engine::general_purpose::STANDARD.decode(encoded.trim()).ok()?;
    let items = der_items(&raw)?;
    let ((0x30, algorithm), (0x04, data)) = (items.get(1)?.clone(), items.get(2)?.clone()) else { return None };
    let algorithm = der_children(algorithm)?;
    let ((0x06, oid), (0x04, iv)) = (algorithm.first()?.clone(), algorithm.get(1)?.clone()) else { return None };
    let cipher = match (oid, iv.len()) { (OID_DES3_CBC, 8) => "des3", (OID_AES256_CBC, 16) => "aes", _ => return None };
    (!data.is_empty() && data.len() <= 16_384).then(|| json!({"cipher": cipher, "iv": b64(iv), "data": b64(data)}))
}
/// Firefox's saved logins from its last used profile, still encrypted: the key store's
/// salt and items plus each login's fields, which only the host decrypts.
pub fn firefox_logins(home: &str) -> Result<Value, &'static str> {
    use base64::Engine;
    let home = Path::new(home);
    if !home.is_absolute() {
        return Err("Invalid home folder.");
    }
    let profile = firefox_places(home).and_then(|p| p.parent().map(Path::to_path_buf)).ok_or("Firefox wasn’t found on this Mac.")?;
    let logins: Value = serde_json::from_slice(&read_bounded(&profile.join("logins.json")).map_err(|_| "Firefox has no saved passwords on this Mac.")?)
        .map_err(|_| "Firefox’s saved passwords use an unsupported format.")?;
    let copy = std::env::temp_dir().join(format!("neutrino-key4-{}.sqlite", std::process::id()));
    std::fs::write(&copy, read_bounded(&profile.join("key4.db")).map_err(|_| "Firefox’s password key wasn’t found.")?)
        .map_err(|_| "Firefox’s password key couldn’t be copied for import.")?;
    let keys = (|| {
        let db = rusqlite::Connection::open_with_flags(&copy, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(|_| "Firefox’s password key couldn’t be opened.")?;
        let (salt, check): (Vec<u8>, Vec<u8>) = db
            .query_row("SELECT item1, item2 FROM metaData WHERE id = 'password'", [], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(|_| "Firefox’s password key uses an unsupported format.")?;
        let id: &[u8] = &[0xf8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1];
        let mut query = db.prepare("SELECT a11, a102 FROM nssPrivate").map_err(|_| "Firefox’s password key uses an unsupported format.")?;
        let key = query
            .query_map([], |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, Vec<u8>>(1)?)))
            .map_err(|_| "Firefox’s password key couldn’t be read.")?
            .flatten()
            .find(|(_, a102)| a102 == id)
            .map(|(a11, _)| a11)
            .ok_or("Firefox’s password key wasn’t found.")?;
        Ok::<_, &'static str>((salt, check, key))
    })();
    let _ = std::fs::remove_file(&copy);
    let (salt, check, key) = keys?;
    // Profiles from before 2019 use an older scheme; their passwords can be exported as CSV.
    let (Some(check), Some(key)) = (firefox_pbes2(&check), firefox_pbes2(&key)) else {
        return Err("This Firefox profile uses an older password format. Export a CSV from Firefox instead.");
    };
    let found: Vec<Value> = array(&logins["logins"]).iter().take(5000).filter_map(|l| {
        let origin = l["hostname"].as_str().filter(|o| web(o) && o.len() <= 2048)?;
        Some(json!({"origin": origin, "username": firefox_field(l["encryptedUsername"].as_str()?)?, "password": firefox_field(l["encryptedPassword"].as_str()?)?}))
    }).collect();
    if found.is_empty() {
        return Err("Firefox has no saved passwords on this Mac.");
    }
    Ok(json!({"globalSalt": base64::engine::general_purpose::STANDARD.encode(salt), "check": check, "key": key, "logins": found}))
}

#[cfg(test)]
mod tests {
    use super::*;

    // A key store and logins made as NSS makes them (PBES2 with PBKDF2-HMAC-SHA256 and
    // AES-256-CBC; logins in 3DES-CBC), from a fixed salt and key.
    const FIREFOX_CHECK: &str = "308182306e06092a864886f70d01050d3061304206092a864886f70d01050c30350420070707070707070707070707070707070707070707070707070707070707070702022710020120300a06082a864886f70d0209301b060960864801650304012a040e09090909090909090909090909090410ee92a0e9f954b4ba745b00d454fee861";
    const FIREFOX_KEY: &str = "308192306e06092a864886f70d01050d3061304206092a864886f70d01050c30350420050505050505050505050505050505050505050505050505050505050505050502022710020120300a06082a864886f70d0209301b060960864801650304012a040e03030303030303030303030303030420d32d2813b7954b0e789c03c1eef3aa5fabf7173f586e9cc2523c5c0d40cd087d";
    const FIREFOX_USERNAME: &str = "MDoEEPgAAAAAAAAAAAAAAAAAAAEwFAYIKoZIhvcNAwcECAEBAQEBAQEBBBBhM6DTSre88jrDlqX1qexG";
    const FIREFOX_PASSWORD: &str = "MEIEEPgAAAAAAAAAAAAAAAAAAAEwFAYIKoZIhvcNAwcECAICAgICAgICBBjEbqDd/qCdwi11SCXGCP5jKfgz5Uf8UMU=";

    #[test]
    fn reads_firefox_key_store_and_logins_still_encrypted() {
        let hex = |h: &str| (0..h.len()).step_by(2).map(|i| u8::from_str_radix(&h[i..i + 2], 16).unwrap()).collect::<Vec<u8>>();
        let home = std::env::temp_dir().join(format!("neutrino-firefox-test-{}", std::process::id()));
        let profile = home.join("Library/Application Support/Firefox/Profiles/abc.default-release");
        std::fs::create_dir_all(&profile).unwrap();
        std::fs::write(profile.join("places.sqlite"), b"").unwrap();
        let db = rusqlite::Connection::open(profile.join("key4.db")).unwrap();
        db.execute_batch("CREATE TABLE metaData (id, item1, item2); CREATE TABLE nssPrivate (id, a11, a102);").unwrap();
        db.execute("INSERT INTO metaData VALUES ('password', ?1, ?2)", rusqlite::params![(1u8..=20).collect::<Vec<u8>>(), hex(FIREFOX_CHECK)]).unwrap();
        let id: Vec<u8> = [vec![0xf8], vec![0; 14], vec![1]].concat();
        db.execute("INSERT INTO nssPrivate VALUES (1, ?1, ?2)", rusqlite::params![hex(FIREFOX_KEY), id]).unwrap();
        drop(db);
        let logins = json!({"logins": [
            {"hostname": "https://example.com", "encryptedUsername": FIREFOX_USERNAME, "encryptedPassword": FIREFOX_PASSWORD},
            {"hostname": "chrome://FirefoxAccounts", "encryptedUsername": FIREFOX_USERNAME, "encryptedPassword": FIREFOX_PASSWORD},
        ]});
        std::fs::write(profile.join("logins.json"), logins.to_string()).unwrap();
        let found = firefox_logins(home.to_str().unwrap()).unwrap();
        let _ = std::fs::remove_dir_all(&home);
        assert_eq!(found["globalSalt"], "AQIDBAUGBwgJCgsMDQ4PEBESExQ=");
        assert_eq!(found["check"]["iterations"], 10000);
        assert_eq!(found["check"]["iv"], "BA4JCQkJCQkJCQkJCQkJCQ==");
        assert_eq!(found["key"]["iv"], "BA4DAwMDAwMDAwMDAwMDAw==");
        let rows = found["logins"].as_array().unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["origin"], "https://example.com");
        assert_eq!(rows[0]["username"]["cipher"], "des3");
        assert_eq!(rows[0]["username"]["iv"], "AQEBAQEBAQE=");
        assert!(firefox_pbes2(&hex(FIREFOX_CHECK)[..40]).is_none());
        assert!(firefox_field("bm90IERFUg==").is_none());
    }

    #[test]
    fn reads_chromium_logins_as_encrypted_values() {
        let home = std::env::temp_dir().join(format!("neutrino-logins-test-{}", std::process::id()));
        let folder = home.join("Library/Application Support/BraveSoftware/Brave-Browser/Default");
        std::fs::create_dir_all(&folder).unwrap();
        let db = rusqlite::Connection::open(folder.join("Login Data")).unwrap();
        db.execute_batch("CREATE TABLE logins (origin_url TEXT, username_value TEXT, password_value BLOB);
            INSERT INTO logins VALUES ('https://a.example/', 'me', X'763130AA'), ('https://never.example/', '', X''), ('android://app', 'x', X'7631');").unwrap();
        drop(db);
        let found = logins("brave", home.to_str().unwrap()).unwrap();
        assert_eq!(found.as_array().unwrap().len(), 1);
        assert_eq!(found[0]["encrypted"], "djEwqg==");
        assert!(logins("safari", home.to_str().unwrap()).is_err());
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn chromium_bookmarks_flatten_folders_and_skip_non_web_addresses() {
        let document = json!({"roots":{
            "bookmark_bar":{"type":"folder","children":[
                {"type":"url","name":"Docs","url":"https://docs.example.com/"},
                {"type":"folder","name":"Work","children":[{"type":"url","name":"Board","url":"https://example.com/board"}]},
                {"type":"url","name":"Script","url":"javascript:alert(1)"}
            ]},
            "other":{"type":"folder","children":[{"type":"url","name":"Local","url":"file:///etc/hosts"}]}
        }});
        let found = parse_chromium(&document);
        assert_eq!(found.len(), 2);
        assert_eq!(found[1]["url"], "https://example.com/board");
    }

    #[test]
    fn reads_a_chromium_profile_from_the_home_folder() {
        let home = std::env::temp_dir().join(format!("neutrino-import-{}", std::process::id()));
        let folder = home.join("Library/Application Support/Vivaldi/Default");
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(folder.join("Bookmarks"), r#"{"roots":{"bookmark_bar":{"type":"folder","children":[{"type":"url","name":"A","url":"https://a.example/"}]}}}"#).unwrap();
        let found = bookmarks("vivaldi", home.to_str().unwrap()).unwrap();
        assert_eq!(found[0]["title"], "A");
        assert!(bookmarks("chrome", home.to_str().unwrap()).is_err());
        assert!(bookmarks("vivaldi", "relative/home").is_err());
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn reads_the_profile_the_browser_last_used() {
        let home = std::env::temp_dir().join(format!("neutrino-import-profile-{}", std::process::id()));
        let root = home.join("Library/Application Support/Google/Chrome");
        for (profile, title) in [("Default", "Home"), ("Profile 2", "Work")] {
            std::fs::create_dir_all(root.join(profile)).unwrap();
            std::fs::write(root.join(profile).join("Bookmarks"), format!(r#"{{"roots":{{"bookmark_bar":{{"type":"folder","children":[{{"type":"url","name":"{title}","url":"https://a.example/"}}]}}}}}}"#)).unwrap();
        }
        let read = || bookmarks("chrome", home.to_str().unwrap()).unwrap()[0]["title"].clone();
        assert_eq!(read(), "Home");
        std::fs::write(root.join("Local State"), r#"{"profile":{"last_used":"Profile 2"}}"#).unwrap();
        assert_eq!(read(), "Work");
        // A name that leaves the browser's folder, or a missing profile, falls back to Default.
        std::fs::write(root.join("Local State"), r#"{"profile":{"last_used":"../../.."}}"#).unwrap();
        assert_eq!(read(), "Home");
        std::fs::write(root.join("Local State"), r#"{"profile":{"last_used":"Profile 9"}}"#).unwrap();
        assert_eq!(read(), "Home");
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn reads_chromium_history_newest_first_in_reference_seconds() {
        let home = std::env::temp_dir().join(format!("neutrino-history-test-{}", std::process::id()));
        let folder = home.join("Library/Application Support/Google/Chrome/Default");
        std::fs::create_dir_all(&folder).unwrap();
        let db = rusqlite::Connection::open(folder.join("History")).unwrap();
        db.execute_batch("CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, last_visit_time INTEGER);
            INSERT INTO urls (url, title, last_visit_time) VALUES ('https://old.example/', 'Old', 13000000000000000), ('https://new.example/', 'New', 13300000000000000), ('chrome://settings/', 'Settings', 13400000000000000);").unwrap();
        drop(db);
        let found = history("chrome", home.to_str().unwrap()).unwrap();
        assert_eq!(found.as_array().unwrap().len(), 2);
        assert_eq!(found[0]["url"], "https://new.example/");
        let seconds = found[0]["visitedAt"].as_f64().unwrap();
        assert!((seconds - (13_300_000_000.0 - 11_644_473_600.0 - REFERENCE)).abs() < 1.0);
        std::fs::remove_dir_all(home).unwrap();
    }
}
