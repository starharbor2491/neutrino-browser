// SPDX-License-Identifier: MPL-2.0
//! Reads bookmarks other browsers keep on this Mac. Chromium-family browsers share
//! one JSON format; Firefox keeps an SQLite database. Safari is read by the host.
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
}
