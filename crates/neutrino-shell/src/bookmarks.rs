// SPDX-License-Identifier: MPL-2.0
//! Linear-time Netscape bookmark exchange. Imported markup is data, never executed.
use crate::state::{array, text};
use serde_json::{json, Value};
use std::collections::HashSet;
fn space(b: u8) -> bool {
    matches!(b, 9 | 10 | 12 | 13 | 32)
}
fn entities(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'&' {
            let mut end = i + 1;
            while end < bytes.len() && end - i <= 32 && bytes[end] != b';' && bytes[end] != b'&' {
                end += 1;
            }
            if end < bytes.len() && bytes[end] == b';' && end - i <= 32 {
                let entity = String::from_utf8_lossy(&bytes[i + 1..end]);
                let replacement = match entity.as_ref() {
                    "amp" | "AMP" => Some('&'),
                    "quot" | "QUOT" => Some('"'),
                    "apos" => Some('\''),
                    "lt" | "LT" => Some('<'),
                    "gt" | "GT" => Some('>'),
                    "nbsp" => Some('\u{a0}'),
                    _ => {
                        let n = if let Some(d) = entity
                            .strip_prefix("#x")
                            .or_else(|| entity.strip_prefix("#X"))
                        {
                            u32::from_str_radix(d, 16).ok()
                        } else {
                            entity.strip_prefix('#').and_then(|d| d.parse().ok())
                        };
                        n.filter(|v| *v != 0).and_then(char::from_u32)
                    }
                };
                if let Some(c) = replacement {
                    out.extend_from_slice(c.encode_utf8(&mut [0; 4]).as_bytes());
                    i = end + 1;
                    continue;
                }
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}
fn href(bytes: &[u8], mut i: usize, end: usize) -> Option<String> {
    while i < end {
        while i < end && (space(bytes[i]) || bytes[i] == b'/') {
            i += 1;
        }
        let start = i;
        while i < end && !space(bytes[i]) && bytes[i] != b'=' && bytes[i] != b'/' {
            i += 1;
        }
        let name = String::from_utf8_lossy(&bytes[start..i]).to_ascii_lowercase();
        while i < end && space(bytes[i]) {
            i += 1;
        }
        if i >= end || bytes[i] != b'=' {
            continue;
        }
        i += 1;
        while i < end && space(bytes[i]) {
            i += 1;
        }
        if i >= end {
            return None;
        }
        let quote = if [b'"', b'\''].contains(&bytes[i]) {
            let q = bytes[i];
            i += 1;
            Some(q)
        } else {
            None
        };
        let start = i;
        while i < end && quote.map_or(!space(bytes[i]), |q| bytes[i] != q) {
            i += 1;
        }
        if name == "href" {
            return (i > start && i - start <= 8192)
                .then(|| entities(&String::from_utf8_lossy(&bytes[start..i])));
        }
        if quote.is_some() && i < end {
            i += 1;
        }
    }
    None
}
pub fn parse(input: &str) -> Result<Value, &'static str> {
    if input.len() > 10 * 1024 * 1024 {
        return Err("Choose a UTF-8 bookmarks HTML file smaller than 10 MB.");
    }
    let bytes = input.as_bytes();
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    let mut pending: Option<String> = None;
    let mut title = Vec::new();
    let mut completed = 0;
    let mut i = 0;
    while i < bytes.len() && completed < 10_000 {
        if bytes[i] != b'<' {
            if pending.is_some() && title.len() < 16384 {
                title.push(bytes[i]);
            }
            i += 1;
            continue;
        }
        if bytes.get(i + 1..i + 4) == Some(b"!--") {
            i += 4;
            while i + 2 < bytes.len() && bytes.get(i..i + 3) != Some(b"-->") {
                i += 1;
            }
            i = (i + 3).min(bytes.len());
            continue;
        }
        i += 1;
        let closing = bytes.get(i) == Some(&b'/');
        if closing {
            i += 1;
        }
        let start = i;
        while i < bytes.len() && !space(bytes[i]) && ![b'>', b'/', b'<'].contains(&bytes[i]) {
            i += 1;
        }
        let name = String::from_utf8_lossy(&bytes[start..i]).to_ascii_lowercase();
        let attributes = i;
        let mut quote = None;
        while i < bytes.len() {
            let b = bytes[i];
            if let Some(q) = quote {
                if b == q {
                    quote = None;
                }
            } else if b == b'"' || b == b'\'' {
                quote = Some(b);
            } else if b == b'>' || b == b'<' {
                break;
            }
            i += 1;
        }
        if i >= bytes.len() {
            break;
        }
        if bytes[i] == b'<' {
            continue;
        }
        if !closing && ["script", "style"].contains(&name.as_str()) {
            let marker = format!("</{name}");
            i += 1;
            while i < bytes.len() {
                if i + marker.len() < bytes.len()
                    && bytes[i..i + marker.len()].eq_ignore_ascii_case(marker.as_bytes())
                    && (space(bytes[i + marker.len()]) || bytes[i + marker.len()] == b'>')
                {
                    break;
                }
                i += 1;
            }
            continue;
        }
        if name == "a" {
            if closing {
                if let Some(target) = pending.take() {
                    completed += 1;
                    if let Ok(url) = url::Url::parse(&target) {
                        if ["http", "https"].contains(&url.scheme())
                            && url.host_str().is_some()
                            && url.username().is_empty()
                            && url.password().is_none()
                            && seen.insert(url.to_string())
                        {
                            let label = entities(&String::from_utf8_lossy(&title));
                            let label = if label.is_empty() {
                                url.host_str().unwrap_or("Bookmark").to_string()
                            } else {
                                label.chars().take(512).collect()
                            };
                            out.push(json!({"title":label,"url":url.as_str()}));
                        }
                    }
                }
                title.clear();
            } else {
                pending = href(bytes, attributes, i);
                title.clear();
            }
        }
        i += 1;
    }
    if out.is_empty() {
        Err("No HTTP or HTTPS bookmarks were found in that file.")
    } else {
        Ok(json!(out))
    }
}
pub fn export(bookmarks: &Value) -> Value {
    let escape = |s: &str| {
        s.replace('&', "&amp;")
            .replace('"', "&quot;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
    };
    let entries = array(bookmarks)
        .iter()
        .map(|b| {
            format!(
                "<DT><A HREF=\"{}\">{}</A>",
                escape(text(b, "url")),
                escape(text(b, "title"))
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    json!(format!("<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n<TITLE>Neutrino Bookmarks</TITLE>\n<DL><p>\n{entries}\n</DL><p>\n"))
}
