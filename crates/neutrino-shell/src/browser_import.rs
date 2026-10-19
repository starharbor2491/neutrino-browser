// SPDX-License-Identifier: MPL-2.0
//! Reads bookmarks and history other browsers keep on this Mac. Chromium-family
//! browsers share one JSON bookmarks format and one SQLite history format; Firefox
//! and Safari keep SQLite databases. Safari's bookmarks are read by the host.
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

const MAX_BOOKMARKS: usize = 20_000;
const MAX_FILE_BYTES: u64 = 64 * 1024 * 1024;

/// The bookmarks file of a Chromium-family browser's default profile, under ~/Library.
fn chromium_bookmarks(source: &str) -> Option<&'static str> {
    Some(match source {
        "chrome" => "Library/Application Support/Google/Chrome/Default/Bookmarks",
        "edge" => "Library/Application Support/Microsoft Edge/Default/Bookmarks",
        "brave" => "Library/Application Support/BraveSoftware/Brave-Browser/Default/Bookmarks",
        "arc" => "Library/Application Support/Arc/User Data/Default/Bookmarks",
        "vivaldi" => "Library/Application Support/Vivaldi/Default/Bookmarks",
        "opera" => "Library/Application Support/com.operasoftware.Opera/Bookmarks",
        "operagx" => "Library/Application Support/com.operasoftware.OperaGX/Bookmarks",
        _ => return None,
    })
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
            let bookmarks = chromium_bookmarks(source).ok_or("Importing from that browser isn’t supported.")?;
            let history = home.join(bookmarks).with_file_name("History");
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
    let relative = chromium_bookmarks(source).ok_or("Importing from that browser isn’t supported.")?;
    let document: Value = serde_json::from_slice(&read_bounded(&home.join(relative))?)
        .map_err(|_| "That browser’s bookmarks file couldn’t be read.")?;
    Ok(json!(parse_chromium(&document)))
}

#[cfg(test)]
mod tests {
    use super::*;

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
