// SPDX-License-Identifier: MPL-2.0
//! Portable browser services. Swift only converts their JSON ABI to native types.
use crate::state::{array, flag, resolve_address, text, validate_ai};
use serde_json::{json, Value};
use url::Url;

pub const BLOCKED_DOMAINS: &[&str] = &[
    "doubleclick.net",
    "googlesyndication.com",
    "googleadservices.com",
    "google-analytics.com",
    "googletagmanager.com",
    "adnxs.com",
    "adsrvr.org",
    "criteo.com",
    "criteo.net",
    "scorecardresearch.com",
    "quantserve.com",
    "taboola.com",
    "outbrain.com",
    "hotjar.com",
    "hotjar.io",
    "clarity.ms",
    "facebook.net",
    "segment.io",
];
pub fn request(r: Value) -> Result<Value, &'static str> {
    Ok(match text(&r, "op") {
        "manageNamedSetup" | "normalizeSession" | "sessionAncestors" | "visibleTreeTabs" | "setTabParent" | "selectSessionTab" | "enableSessionSplit" | "normalizeSpace" | "archiveIdleTabs" | "restoreArchivedTab" | "normalizeSpaces" | "normalizeLibrary" | "spaceConfiguration" | "removeProfile" | "restoreProfile" | "normalizeChromiumPages" => crate::workspace::request(&r)?,
        "communityPayload" | "validateCommunityCatalog" => crate::module_repository::community_request(&r),
        "validateMinimumMacOS" | "validateRelease" | "validateDistributionAsset" | "validateDistributionCatalog" | "distributionUpdates" | "validateEngineManifest" | "validateIdentity" | "validateResourceFrame" | "normalizeSetupPack" | "boundedImport" => crate::policy::request(&r),
        "moduleRepository" => crate::module_repository::request(&r),
        "validateUpdatePolicy" => {
            if r["build"].as_u64().unwrap_or(0) < r["currentBuild"].as_u64().unwrap_or(0) ||
               r["epoch"].as_u64().is_none_or(|e|e<r["floor"].as_u64().unwrap_or(u64::MAX)) {
                return Err("Neutrino will not install an older application or an engine below the accepted security version.");
            }
            json!(true)
        },
        "moduleID"=>json!(crate::modules::id(text(&r,"value"))),
        "moduleJSONBounds"=>{crate::modules::json_bounds(text(&r,"json"))?;json!(true)},
        "validateDefinition"=>{crate::modules::definition(&r["definition"],text(&r,"capability"))?;json!(true)},
        "validateManifest"=>{crate::modules::manifest(&r["manifest"])?;json!(true)},
        "validateSetting"=>{crate::modules::setting(&r["setting"],&r["value"])?;json!(true)},
        "installationPlan"=>crate::modules::plan(text(&r,"id"),&r["catalog"],&r["installed"],flag(&r,"includeInstalled"))?,
        "uninstallPaths"=>crate::uninstall::paths(text(&r,"home"),text(&r,"dataDirectory"))?,
        "uninstallKeychainService"=>json!(crate::uninstall::service(text(&r,"service"))),
        "prepareNote" => {
            let url=resolve_address(text(&r,"url"),"").ok_or("Open a website before saving a page note.")?;
            let title=text(&r,"title").chars().take(100).collect::<String>();
            let quote=text(&r,"quote").chars().take(16_000).collect::<String>();
            json!({"title":title,"text":"","sourceTitle":title,"sourceURL":url,"quote":quote})
        },
        "moduleValue" => {crate::modules::value(&r["value"],r["depth"].as_u64().unwrap_or(0) as usize)?;json!(true)},
        "moduleKey" => json!(crate::modules::key(text(&r,"value"))),
        "validateProgram" => {crate::modules::validate(&r["program"],text(&r,"capability"))?;json!(true)},
        "runProgram" => crate::modules::run(&r["program"],text(&r,"event"),&r["input"] )?,
        "appearancePreset" => crate::appearance::preset(text(&r,"id")).ok_or("Unknown browser preset.")?,
        "normalizeTheme" => crate::appearance::normalize_theme(r["value"].clone()),
        "normalizeLayout" => crate::appearance::normalize_layout(r["value"].clone()),
        "validateSVGIcons" => {crate::modules::svg_icons(&r["icons"])?;json!(true)},
        "parseBookmarks" => crate::bookmarks::parse(text(&r,"html"))?,
        "exportBookmarks" => crate::bookmarks::export(&r["bookmarks"]),
        "resolveAddress" => json!(resolve_address(text(&r,"input"), text(&r,"search"))),
        "isWebURL" => json!(Url::parse(text(&r,"url")).is_ok_and(|u| matches!(u.scheme(),"http"|"https") && u.host_str().is_some() && u.username().is_empty() && u.password().is_none())),
        "pageTitle" => json!(text(&r,"title").chars().take(512).collect::<String>()),
        "validateAI" => {
            if !validate_ai(text(&r,"provider"),text(&r,"endpoint"),text(&r,"model")) {
                return Err("Enter a model and a valid provider endpoint. Remote models require HTTPS; provider keys stay on their provider’s host.");
            }
            json!(Url::parse(text(&r,"endpoint")).map_err(|_| "Invalid endpoint")?.to_string())
        }
        "blockingDomains" => json!(BLOCKED_DOMAINS),
        "blocks" => json!(!flag(&r,"topLevel") && Url::parse(text(&r,"url")).ok().and_then(|u|u.host_str().map(str::to_owned)).is_some_and(|h| BLOCKED_DOMAINS.iter().any(|d| h == *d || h.ends_with(&format!(".{d}"))))),
        "webKitRules" => json!(BLOCKED_DOMAINS.iter().map(|d|json!({"trigger":{"url-filter":format!(r"^https?://([^/]+\.)?{}[/:]",d.replace('.',r"\.")),"resource-type":["image","style-sheet","script","font","raw","media","popup"]},"action":{"type":"block"}})).collect::<Vec<_>>()),
        "reader" => json!(reader(text(&r,"html"))?),
        "validateOrganization" => {
            let proposal=&r["proposal"];
            let Some(folders)=proposal["folders"].as_array() else { return Err("The proposal must contain folders.") };
            let mut seen=std::collections::HashSet::new();
            let known:std::collections::HashSet<_>=array(&r["knownTabs"]).iter().filter_map(Value::as_str).map(str::to_ascii_lowercase).collect();
            if folders.len()>100 || proposal.to_string().len()>65536 {return Err("The organization proposal is too large.")}
            for folder in folders {
                let name=text(folder,"name"); let tabs=array(&folder["tabIDs"]);
                if name.trim().is_empty() || name.chars().count()>80 || tabs.is_empty() {return Err("The proposal contains an invalid folder.")}
                for tab in tabs { let id=tab.as_str().ok_or("Invalid tab identifier.")?.to_ascii_lowercase(); if !known.contains(&id)||!seen.insert(id)||seen.len()>200 {return Err("The proposal contains duplicated tabs or tabs outside this Space.")} }
            }
            proposal.clone()
        }
        _ => return Err("Unknown portable browser operation."),
    })
}
fn reader(html: &str) -> Result<String, &'static str> {
    if html.len() > 1024 * 1024 {
        return Err("Reader supports page snapshots up to 1 MB.");
    }
    // roxmltree has DTD processing disabled; it never reads files, executes scripts,
    // resolves network entities, or repairs malformed markup into a different tree.
    let doc = roxmltree::Document::parse_with_options(
        html,
        roxmltree::ParsingOptions {
            allow_dtd: false,
            nodes_limit: 100_000,
            ..Default::default()
        },
    )
    .map_err(|_| {
        "Reader requires a valid serialized page without document type or entity declarations."
    })?;
    let excluded = |n: roxmltree::Node<'_, '_>| {
        n.ancestors().any(|x| {
            x.is_element()
                && (matches!(
                    x.tag_name().name(),
                    "head"
                        | "script"
                        | "style"
                        | "nav"
                        | "footer"
                        | "aside"
                        | "form"
                        | "noscript"
                        | "template"
                ) || x.has_attribute("hidden")
                    || x.attribute("aria-hidden") == Some("true"))
        })
    };
    let root = ["article", "main", "body"]
        .iter()
        .find_map(|name| {
            doc.descendants()
                .find(|n| n.is_element() && n.tag_name().name() == *name && !excluded(*n))
        })
        .unwrap_or(doc.root_element());
    let mut output = String::new();
    let mut length = 0;
    let mut stack = vec![(root, false)];
    while let Some((node, closing)) = stack.pop() {
        if length >= 200_000 {
            break;
        }
        if excluded(node) {
            continue;
        }
        let block = node.is_element()
            && matches!(
                node.tag_name().name(),
                "p" | "div"
                    | "section"
                    | "article"
                    | "main"
                    | "h1"
                    | "h2"
                    | "h3"
                    | "h4"
                    | "h5"
                    | "h6"
                    | "li"
                    | "blockquote"
                    | "pre"
                    | "tr"
                    | "td"
                    | "th"
                    | "br"
            );
        if node.is_text() {
            for c in node.text().unwrap_or("").chars().take(200_000 - length) {
                output.push(c);
                length += 1;
            }
        } else {
            if block {
                output.push('\n');
                length += 1;
            }
            if !closing {
                stack.push((node, true));
                stack.extend(node.children().rev().map(|n| (n, false)));
            }
        }
    }
    let mut lines = Vec::new();
    for line in output.lines() {
        let mut clean = String::new();
        let mut space = false;
        for c in line.chars() {
            if matches!(c, ' ' | '\t' | '\r') {
                if !space {
                    clean.push(' ')
                }
                space = true;
            } else {
                clean.push(c);
                space = false;
            }
        }
        let clean = clean.trim();
        if !clean.is_empty() {
            lines.push(clean.to_string());
        }
    }
    let result: String = lines.join("\n\n").chars().take(200_000).collect();
    if result.is_empty() {
        Err("This page has no readable text.")
    } else {
        Ok(result)
    }
}
