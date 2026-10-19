// SPDX-License-Identifier: MPL-2.0
//! RSS and Atom feeds for the Feeds panel, parsed without fetching anything.
use serde_json::{json, Value};

fn first<const N: usize>(values: [String; N]) -> String {
    values.into_iter().find(|v| !v.is_empty()).unwrap_or_default()
}

/// The feed's title and its newest entries: title, address and date as given.
pub fn parse(xml: &str) -> Result<Value, &'static str> {
    if xml.len() > 5 * 1024 * 1024 {
        return Err("That feed is larger than 5 MB.");
    }
    // Feeds often declare a DOCTYPE; entities are still never expanded or fetched.
    let doc = roxmltree::Document::parse_with_options(xml, roxmltree::ParsingOptions { allow_dtd: true, nodes_limit: 200_000, ..Default::default() })
        .map_err(|_| "That address doesn’t return a valid RSS or Atom feed.")?;
    let root = doc.root_element();
    let child_text = |node: roxmltree::Node<'_, '_>, name: &str| {
        node.children().find(|c| c.is_element() && c.tag_name().name() == name).and_then(|c| c.text()).map(|t| t.trim().chars().take(300).collect::<String>()).unwrap_or_default()
    };
    let (title, entries) = match root.tag_name().name() {
        "rss" | "RDF" => {
            let channel = root.children().find(|c| c.is_element() && c.tag_name().name() == "channel").unwrap_or(root);
            let items: Vec<Value> = root
                .descendants()
                .filter(|n| n.is_element() && n.tag_name().name() == "item")
                .take(50)
                .map(|item| json!({"title":child_text(item, "title"),"url":child_text(item, "link"),"date":(first([child_text(item, "pubDate"), child_text(item, "date")]))}))
                .collect();
            (child_text(channel, "title"), items)
        }
        "feed" => {
            let items: Vec<Value> = root
                .children()
                .filter(|n| n.is_element() && n.tag_name().name() == "entry")
                .take(50)
                .map(|entry| {
                    let link = entry
                        .children()
                        .filter(|c| c.is_element() && c.tag_name().name() == "link")
                        .find(|c| c.attribute("rel").is_none_or(|r| r == "alternate"))
                        .and_then(|c| c.attribute("href"))
                        .unwrap_or_default();
                    json!({"title":child_text(entry, "title"),"url":link,"date":(first([child_text(entry, "updated"), child_text(entry, "published")]))})
                })
                .collect();
            (child_text(root, "title"), items)
        }
        _ => return Err("That address doesn’t return a valid RSS or Atom feed."),
    };
    let entries: Vec<Value> = entries.into_iter().filter(|e| e["url"].as_str().is_some_and(|u| u.starts_with("https://") || u.starts_with("http://"))).collect();
    Ok(json!({"title":title,"entries":entries}))
}

#[cfg(test)]
mod tests {
    #[test]
    fn reads_rss_and_atom() {
        let rss = r#"<?xml version="1.0"?><rss version="2.0"><channel><title>News</title><item><title>One</title><link>https://example.com/1</link><pubDate>Mon, 19 Oct 2026 09:00:00 GMT</pubDate></item><item><title>Bad</title><link>javascript:alert(1)</link></item></channel></rss>"#;
        let parsed = super::parse(rss).unwrap();
        assert_eq!(parsed["title"], "News");
        assert_eq!(parsed["entries"].as_array().unwrap().len(), 1);
        let atom = r#"<feed xmlns="http://www.w3.org/2005/Atom"><title>Blog</title><entry><title>Post</title><link rel="alternate" href="https://blog.example/post"/><updated>2026-10-19T09:00:00Z</updated></entry></feed>"#;
        let parsed = super::parse(atom).unwrap();
        assert_eq!(parsed["entries"][0]["url"], "https://blog.example/post");
        assert!(super::parse("<html></html>").is_err());
    }
}
