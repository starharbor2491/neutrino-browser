// SPDX-License-Identifier: MPL-2.0
//! Portable browser services. Swift only converts their JSON ABI to native types.
use crate::state::{array, flag, resolve_address, text, validate_ai};
use serde_json::{json, Value};
use url::Url;

/// Analytics and cross-site tracking hosts, blocked at every blocking level.
pub const TRACKER_DOMAINS: &[&str] = &[
    "google-analytics.com",
    "googletagmanager.com",
    "scorecardresearch.com",
    "quantserve.com",
    "hotjar.com",
    "hotjar.io",
    "clarity.ms",
    "facebook.net",
    "segment.io",
    "mixpanel.com",
    "fullstory.com",
    "newrelic.com",
    "chartbeat.com",
    "analytics.google.com",
    "analytics.twitter.com",
    "analytics.tiktok.com",
    "ct.pinterest.com",
    "bat.bing.com",
    "snap.licdn.com",
    "sc-static.net",
    "tr.snapchat.com",
    "amplitude.com",
    "heapanalytics.com",
    "mouseflow.com",
    "crazyegg.com",
    "luckyorange.com",
    "luckyorange.net",
    "inspectlet.com",
    "kissmetrics.com",
    "adjust.com",
    "appsflyer.com",
    "kochava.com",
    "omtrdc.net",
    "2o7.net",
    "demdex.net",
    "everesttech.net",
    "krxd.net",
    "bluekai.com",
    "exelator.com",
    "rlcdn.com",
    "agkn.com",
    "tapad.com",
    "crwdcntrl.net",
    "addthis.com",
    "sharethis.com",
    "cloudflareinsights.com",
    "statcounter.com",
    "mc.yandex.ru",
    "parsely.com",
    "parse.ly",
    "smartlook.com",
    "nr-data.net",
    "imrworldwide.com",
    "quantcount.com",
    "mxpnl.com",
    "pixel.wp.com",
];
/// Advertising hosts, blocked when ads are blocked as well.
pub const AD_DOMAINS: &[&str] = &[
    "doubleclick.net",
    "googlesyndication.com",
    "googleadservices.com",
    "adnxs.com",
    "adsrvr.org",
    "criteo.com",
    "criteo.net",
    "taboola.com",
    "outbrain.com",
    "amazon-adsystem.com",
    "pubmatic.com",
    "rubiconproject.com",
    "googletagservices.com",
    "adservice.google.com",
    "static.ads-twitter.com",
    "ads.linkedin.com",
    "advertising.com",
    "yieldmo.com",
    "openx.net",
    "casalemedia.com",
    "indexww.com",
    "smartadserver.com",
    "teads.tv",
    "33across.com",
    "sharethrough.com",
    "triplelift.com",
    "3lift.com",
    "media.net",
    "bidswitch.net",
    "contextweb.com",
    "lijit.com",
    "sovrn.com",
    "spotxchange.com",
    "spotx.tv",
    "adform.net",
    "adition.com",
    "mgid.com",
    "revcontent.com",
    "zemanta.com",
    "adroll.com",
    "serving-sys.com",
    "flashtalking.com",
    "moatads.com",
    "adsafeprotected.com",
    "doubleverify.com",
    "zedo.com",
    "popads.net",
    "propellerads.com",
    "exoclick.com",
    "adcolony.com",
    "applovin.com",
    "inmobi.com",
    "smaato.net",
    "chartboost.com",
    "vungle.com",
    "carbonads.net",
    "buysellads.com",
    "yieldlab.net",
    "adsymptotic.com",
    "lkqd.net",
];
/// Hosts blocked at a level: trackers always, ads unless the request turns them off,
/// and the person's own rules.
fn blocked_domains(r: &Value) -> Vec<String> {
    let ads = r["ads"].as_bool().unwrap_or(true);
    let mut out: Vec<String> = TRACKER_DOMAINS.iter().chain(if ads { AD_DOMAINS } else { &[] }).map(|d| d.to_string()).collect();
    for d in array(&r["custom"]).iter().filter_map(Value::as_str).take(5000) {
        let d = d.to_ascii_lowercase();
        if d.contains('.') && d.len() <= 253 && d.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-') && !out.contains(&d) {
            out.push(d);
        }
    }
    out
}
/// WebKit content rules for a blocking level, with sites whose Shields are down exempt.
fn webkit_rules(r: &Value) -> Value {
    let mut rules: Vec<Value> = blocked_domains(r).iter().map(|d| json!({"trigger":{"url-filter":format!(r"^https?://([^/]+\.)?{}[/:]",d.replace('.',r"\.")),"resource-type":["image","style-sheet","script","font","raw","media","popup"]},"action":{"type":"block"}})).collect();
    let exempt: Vec<Value> = array(&r["exceptions"]).iter().filter_map(Value::as_str)
        .filter(|h| !h.is_empty() && h.len() <= 253 && h.bytes().all(|b| b.is_ascii_alphanumeric() || b"-.".contains(&b)))
        .take(500).map(|h| json!(format!("*{}", h.to_ascii_lowercase()))).collect();
    if !exempt.is_empty() {
        rules.push(json!({"trigger":{"url-filter":".*","if-domain":exempt},"action":{"type":"ignore-previous-rules"}}));
    }
    json!(rules)
}
pub fn request(r: Value) -> Result<Value, &'static str> {
    Ok(match text(&r, "op") {
        "moduleNote" | "projectNotes" | "resolveNoteSource" | "prepareForChromiumRemoval" | "applyOrganization" | "liveTabOwnership" | "applySpaceConfiguration" | "manageNamedSetup" | "normalizeSession" | "sessionAncestors" | "visibleTreeTabs" | "setTabParent" | "selectSessionTab" | "enableSessionSplit" | "normalizeSpace" | "archiveIdleTabs" | "restoreArchivedTab" | "normalizeSpaces" | "normalizeLibrary" | "spaceConfiguration" | "removeProfile" | "restoreProfile" | "normalizeChromiumPages" => crate::workspace::request(&r)?,
        "communityPayload" | "validateCommunityCatalog" => crate::module_repository::community_request(&r),
        "githubCatalogURL" | "validateMinimumMacOS" | "validateRelease" | "validateDistributionAsset" | "validateDistributionCatalog" | "distributionUpdates" | "validateEngineManifest" | "validateIdentity" | "validateResourceFrame" | "normalizeSetupPack" | "boundedImport" => crate::policy::request(&r),
        "moduleRepository" => crate::module_repository::request(&r),
        "validateUpdatePolicy" => {
            if r["build"].as_u64().unwrap_or(0) < r["currentBuild"].as_u64().unwrap_or(0) ||
               r["epoch"].as_u64().is_none_or(|e|e<r["floor"].as_u64().unwrap_or(u64::MAX)) {
                return Err("Neutrino will not install an older application or an engine below the accepted security version.");
            }
            json!(true)
        },
        "focusPresentation" => {
            let active = r["output"]["active"].as_bool().ok_or("Focus Mode returned an invalid transition.")?;
            let components = r["output"]["hiddenComponents"].as_array().ok_or("Focus Mode returned an invalid transition.")?;
            if components.iter().any(|v|v.as_str().is_none()) {return Err("Focus Mode returned an invalid transition.");}
            let names:std::collections::BTreeSet<_> = components.iter().filter_map(Value::as_str).collect();
            if names.len()>5 || names.iter().any(|v|!["tabs","navigation","sidebar","bookmarks","status"].contains(v)) {return Err("Focus Mode requested unsupported interface components.");}
            json!(if active{names.into_iter().collect::<Vec<_>>()}else{vec![]})
        },
        "captureSpecification" => {
            let output=&r["output"];
            let name=output["filename"].as_str().ok_or("This Page Capture package requested an unsupported format or capture area.")?;
            if output["format"]!="png" || output["visibleOnly"]!=true {return Err("This Page Capture package requested an unsupported format or capture area.");}
            let clean:String=name.chars().filter(|c|!['/','\\',':','\0','\r','\n'].contains(c)).take(100).collect();
            json!({"filename":if clean.is_empty(){"Page Capture.png".into()}else{format!("{clean}.png")},"visibleOnly":true})
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
        "browserHistory" => crate::browser_import::history(text(&r, "source"), text(&r, "home"))?,
        "browserBookmarks" => crate::browser_import::bookmarks(text(&r, "source"), text(&r, "home"))?,
        "resolveAddress" => json!(resolve_address(text(&r,"input"), text(&r,"search"))),
        "isWebURL" => json!(Url::parse(text(&r,"url")).is_ok_and(|u| matches!(u.scheme(),"http"|"https") && u.host_str().is_some() && u.username().is_empty() && u.password().is_none())),
        "pageTitle" => json!(text(&r,"title").chars().take(512).collect::<String>()),
        "validateAI" => {
            if !validate_ai(text(&r,"provider"),text(&r,"endpoint"),text(&r,"model")) {
                return Err("Enter a model and a valid provider endpoint. Remote models require HTTPS; provider keys stay on their provider’s host.");
            }
            json!(Url::parse(text(&r,"endpoint")).map_err(|_| "Invalid endpoint")?.to_string())
        }
        "blockingDomains" => json!(blocked_domains(&r)),
        "blocks" => json!(!flag(&r,"topLevel") && Url::parse(text(&r,"url")).ok().and_then(|u|u.host_str().map(str::to_owned)).is_some_and(|h| blocked_domains(&r).iter().any(|d| h == *d || h.ends_with(&format!(".{d}"))))),
        "pageScript" => json!(crate::features::page_script(&r).ok_or("Unknown page script.")?),
        "stripTracking" => json!(crate::features::strip_tracking(text(&r, "url"))),
        "parseBlockRules" => json!(crate::features::parse_rules(text(&r, "value"))),
        "webKitRules" => webkit_rules(&r),
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
pub(crate) fn reader(html: &str) -> Result<String, &'static str> {
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
