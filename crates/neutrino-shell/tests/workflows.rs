// SPDX-License-Identifier: MPL-2.0
use neutrino_shell::Shell;
use serde_json::{json, Value};
fn shell() -> Shell {
    let mut s = Shell::default();
    s.dispatch(json!({"op":"sync","snapshot":{"completedOnboarding":true,"configuration":{"theme":{"accent":"rose","colorMode":"light","density":"comfortable"},"layout":{"tabs":"leading","tabsWidth":240,"navigation":"top","sidebar":"leading"}},"session":{"profileID":"p1","spaceID":"s1","selectedTabID":"a","tabs":[{"id":"a","title":"Alpha","url":"https://example.com/a","pinned":false},{"id":"b","title":"Beta","pinned":false,"parentID":"a"},{"id":"c","title":"Charlie","pinned":false}]},"spaces":[{"id":"s1","profileID":"p1"},{"id":"s2","profileID":"p1"},{"id":"secret","profileID":"p2"}],"folders":[{"id":"f1","name":"Work"}],"preferences":{"search":"duckDuckGo"}}}));
    s
}
fn commands(result: &Value) -> &[Value] {
    result["commands"].as_array().unwrap()
}
#[test]
fn panel_navigation_and_saved_setup_requirements_survive_dispatch() {
    let mut s = shell();
    s.dispatch(json!({"op":"panel","value":"notes"}));
    let r = s.dispatch(json!({"op":"section","value":"history"}));
    assert_eq!(s.panel, "history");
    assert!(commands(&r)
        .iter()
        .any(|c| c["op"] == "projectLibrary" && c["section"] == "history"));
    s.snapshot["savedConfigurations"] = json!([{"id":"saved","name":"Research","configuration":s.snapshot["configuration"],"requiredModuleIDs":["org.neutrino.notes"]}]);
    s.dispatch(json!({"op":"screen","value":"editor"}));
    s.dispatch(json!({"op":"editor-load-named","id":"saved"}));
    let r = s.dispatch(json!({"op":"editor-save"}));
    assert_eq!(
        commands(&r)[0]["requirements"],
        json!(["org.neutrino.notes"])
    );
}
#[test]
fn svg_semantic_keys_reach_the_rendered_glyphs_and_updates_reject_epoch_rollback() {
    let mut s = shell();
    s.snapshot["configuration"]["theme"]["iconPack"] = json!("module");
    s.snapshot["svgIcons"] = json!({"newTab":"M1 2h3","downloads":"M4 5h6"});
    let r = s.dispatch(json!({"op":"sync","snapshot":s.snapshot.clone()}));
    let html = r["html"].as_str().unwrap();
    assert!(html.contains("d=\"M1 2h3\""));
    assert!(html.contains("d=\"M4 5h6\""));
    assert!(neutrino_shell::core_request(
        json!({"op":"validateUpdatePolicy","build":11,"currentBuild":10,"epoch":153,"floor":154})
    )
    .is_err());
    assert!(neutrino_shell::core_request(
        json!({"op":"validateUpdatePolicy","build":11,"currentBuild":10,"epoch":155,"floor":154})
    )
    .is_ok());
}
#[test]
fn tab_move_keeps_document_fields_and_undo_is_context_bound() {
    let mut s = shell();
    let old = s.snapshot["session"]["tabs"].clone();
    let r =
        s.dispatch(json!({"op":"move-tab","id":"a","group":"folder","folderID":"f1","before":"c"}));
    let next = commands(&r)[0]["tabs"].clone();
    let a = next
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["id"] == "a")
        .unwrap();
    assert_eq!(a["url"], "https://example.com/a");
    assert_eq!(a["folderID"], "f1");
    assert_eq!(
        next.as_array()
            .unwrap()
            .iter()
            .find(|v| v["id"] == "b")
            .unwrap()["folderID"],
        "f1"
    );
    s.snapshot["session"]["tabs"] = next;
    assert_eq!(
        commands(&s.dispatch(json!({"op":"undo-tabs"})))[0]["tabs"],
        old
    );
    s.dispatch(json!({"op":"move-tab","id":"a","group":"pinned"}));
    let mut other = s.snapshot.clone();
    other["session"]["spaceID"] = json!("s2");
    s.dispatch(json!({"op":"sync","snapshot":other}));
    assert!(commands(&s.dispatch(json!({"op":"undo-tabs"}))).is_empty());
}
#[test]
fn move_rejects_foreign_tabs_folders_and_profiles() {
    let mut s = shell();
    for request in [
        json!({"op":"move-tab","id":"unknown","group":"today"}),
        json!({"op":"move-tab","id":"a","group":"folder","folderID":"unknown"}),
        json!({"op":"move-space","id":"a","spaceID":"secret"}),
        json!({"op":"move-space","id":"unknown","spaceID":"s2"}),
    ] {
        assert!(commands(&s.dispatch(request)).is_empty());
    }
    assert_eq!(
        commands(&s.dispatch(json!({"op":"move-space","id":"a","spaceID":"s2"})))[0]["op"],
        "moveTabToSpace"
    );
    s.snapshot["private"] = json!(true);
    assert!(commands(&s.dispatch(json!({"op":"move-space","id":"a","spaceID":"s2"}))).is_empty());
}
#[test]
fn undo_wont_resurrect_a_closed_tab() {
    let mut s = shell();
    s.dispatch(json!({"op":"move-tab","id":"a","group":"pinned"}));
    s.snapshot["session"]["tabs"].as_array_mut().unwrap().pop();
    assert!(commands(&s.dispatch(json!({"op":"undo-tabs"}))).is_empty());
}
#[test]
fn editor_draft_is_isolated_recoverable_and_scoped() {
    let mut s = shell();
    let original = s.snapshot["configuration"].clone();
    s.dispatch(json!({"op":"screen","value":"editor"}));
    s.dispatch(json!({"op":"dock","component":"tabs","region":"trailing"}));
    assert_eq!(s.config()["layout"]["tabs"], "trailing");
    assert_eq!(s.snapshot["configuration"], original);
    s.dispatch(json!({"op":"escape"}));
    assert_eq!(s.menu, "discard-editor");
    s.dispatch(json!({"op":"escape"}));
    assert_eq!(s.screen, "editor");
    s.dispatch(json!({"op":"editor-undo"}));
    assert_eq!(s.config(), &original);
    s.dispatch(json!({"op":"editor-value","key":"accent","value":"teal"}));
    s.dispatch(json!({"op":"editor-scope","value":false}));
    let result = s.dispatch(json!({"op":"editor-save"}));
    assert_eq!(commands(&result)[0]["space"], false);
    assert_eq!(
        commands(&result)[0]["configuration"]["theme"]["accent"],
        "teal"
    );
    assert!(s.draft.is_some());
    s.dispatch(json!({"op":"editor-result","action":"applyConfiguration","success":false,"message":"Approval was cancelled."}));
    assert!(s.draft.is_some());
    assert_eq!(s.screen, "editor");
    s.dispatch(json!({"op":"editor-result","action":"applyConfiguration","success":true}));
    assert!(s.draft.is_none());
}
#[test]
fn invalid_docks_and_nonfinite_widths_cannot_corrupt_layout() {
    let mut s = shell();
    s.dispatch(json!({"op":"screen","value":"editor"}));
    let original = s.config().clone();
    for (c, r) in [
        ("navigation", "leading"),
        ("panels", "bottom"),
        ("tabs", "unknown"),
        ("unknown", "top"),
    ] {
        s.dispatch(json!({"op":"dock","component":c,"region":r}));
        assert_eq!(s.config(), &original);
    }
    s.dispatch(json!({"op":"editor-value","key":"tabsWidth","value":99999}));
    assert_eq!(s.config(), &original);
}
#[test]
fn navigation_cannot_execute_code_or_open_local_files() {
    let mut s = shell();
    for url in [
        "javascript:alert(1)",
        "data:text/html,test",
        "file:///etc/passwd",
        "https://user:password@example.com",
        "neutrino-ui://shell/index.html",
        "https://",
    ] {
        assert!(commands(&s.dispatch(json!({"op":"navigate","value":url}))).is_empty());
    }
    assert_eq!(
        commands(&s.dispatch(json!({"op":"navigate","value":"[::1]:8080/test"})))[0]["url"],
        "http://[::1]:8080/test"
    );
}
#[test]
fn rendered_untrusted_titles_are_escaped() {
    let mut s = shell();
    s.snapshot["session"]["tabs"][0]["title"] = json!("<img src=x onerror=alert(1)>");
    let r = s.dispatch(json!({"op":"palette"}));
    let html = r["html"].as_str().unwrap();
    assert!(!html.contains("<img src=x"));
    assert!(html.contains("&lt;img"));
}
#[test]
fn ai_key_only_goes_to_an_explicit_valid_provider_command() {
    let mut s = shell();
    let request = json!({"op":"saveAI","provider":"openAI","endpoint":"https://api.openai.com/v1","model":"model","key":"sensitive-fixture-key"});
    let r = s.dispatch(request);
    assert_eq!(commands(&r)[0]["key"], "sensitive-fixture-key");
    assert!(!r["html"]
        .as_str()
        .unwrap()
        .contains("sensitive-fixture-key"));
    assert!(!s.snapshot.to_string().contains("sensitive-fixture-key"));
    assert!(commands(&s.dispatch(json!({"op":"saveAI","provider":"openAI","endpoint":"https://evil.example/v1","model":"model","key":"secret"}))).is_empty());
}
#[test]
fn setup_validates_names_and_submits_only_once_until_host_responds() {
    let mut s = Shell::default();
    s.step = 1;
    s.dispatch(json!({"op":"setup-field","key":"space","value":" "}));
    s.dispatch(json!({"op":"setup-next"}));
    assert_eq!(s.step, 1);
    s.dispatch(json!({"op":"setup-field","key":"space","value":"Home"}));
    for _ in 0..6 {
        s.dispatch(json!({"op":"setup-next"}));
    }
    assert_eq!(s.step, 7);
    assert_eq!(commands(&s.dispatch(json!({"op":"setup-finish"}))).len(), 1);
    assert!(commands(&s.dispatch(json!({"op":"setup-finish"}))).is_empty());
}
#[test]
fn setup_sends_module_choices_that_follow_the_chosen_browser() {
    let mut s = Shell::default();
    let module = |key: &str| json!({"id":format!("org.neutrino.{key}"),"name":key,"capability":"feature","bundled":true,"installed":true,"enabled":true});
    s.snapshot["modules"] = json!([module("peek"), module("limiter"), {"id":"org.neutrino.notes","name":"Notes","capability":"notes","bundled":true,"installed":true,"enabled":true}, {"id":"org.neutrino.theme-native","name":"macOS Theme","capability":"theme","bundled":true,"installed":false,"enabled":false}]);
    s.dispatch(json!({"op":"setup-field","key":"profile","value":"Personal"}));
    s.dispatch(json!({"op":"setup-field","key":"space","value":"Home"}));
    s.setup["preset"] = json!("arc");
    let flow = ["layout", "arc-welcome", "arc-theme", "arc-import", "arc-favorites", "arc-modules"];
    s.step = flow.len() - 1;
    let html = s.dispatch(json!({"op":"setup-module","value":"org.neutrino.notes"}))["html"].as_str().unwrap().to_string();
    assert!(html.contains("module-picker") && html.contains("data-value=\"org.neutrino.peek\""));
    s.dispatch(json!({"op":"setup-provider","key":"theme","value":"org.neutrino.theme-native"}));
    s.dispatch(json!({"op":"setup-provider","key":"tabSystem","value":""}));
    s.step = 7;
    let finish = commands(&s.dispatch(json!({"op":"setup-finish"})))[0].clone();
    let choices = &finish["setup"]["modules"];
    assert_eq!(choices["org.neutrino.peek"], true);
    assert_eq!(choices["org.neutrino.limiter"], false);
    assert_eq!(choices["org.neutrino.notes"], false);
    assert_eq!(choices["org.neutrino.theme-native"], true);
}
#[test]
fn feeds_subscribe_from_the_page_and_open_entries() {
    let mut s = shell();
    s.snapshot["pageFeed"] = json!("https://example.com/feed.xml");
    s.dispatch(json!({"op":"menu","value":"page"}));
    let r = s.dispatch(json!({"op":"feed","value":"subscribe-page"}));
    assert_eq!(commands(&r)[0], json!({"op":"feedAdd","url":"https://example.com/feed.xml"}));
    let r = s.dispatch(json!({"op":"feed","value":"add","url":"javascript:alert(1)"}));
    assert!(commands(&r).is_empty());
    s.snapshot["preferences"]["feeds"] = json!([{"id":"f1","profileID":"p1","title":"Example news","url":"https://example.com/feed.xml","entries":[
        {"id":"e1","title":"Older","url":"https://example.com/1","time":1.0,"date":"","read":true},
        {"id":"e2","title":"Newer","url":"https://example.com/2","time":2.0,"date":"Oct 19","read":false}]},
        {"id":"f2","profileID":"p2","title":"Someone else","url":"https://other.example/feed","entries":[]}]);
    let html = s.dispatch(json!({"op":"panel","value":"feeds"}))["html"].as_str().unwrap().to_string();
    assert!(html.contains("1 unread") && !html.contains("Someone else"));
    assert!(html.find("Newer").unwrap() < html.find("Older").unwrap());
    let r = s.dispatch(json!({"op":"feed","value":"open","id":"e2"}));
    assert_eq!(commands(&r)[0], json!({"op":"feedOpen","id":"e2","url":"https://example.com/2"}));
    let r = s.dispatch(json!({"op":"feed","value":"remove","id":"missing"}));
    assert!(commands(&r).is_empty());
    s.snapshot["modules"] = json!([{"id":"org.neutrino.feeds","capability":"feature","bundled":true,"installed":true,"enabled":false}]);
    assert!(commands(&s.dispatch(json!({"op":"feed","value":"refresh"}))).is_empty());
}
#[test]
fn clearing_on_quit_is_chosen_per_kind_of_data() {
    let mut s = shell();
    let r = s.dispatch(json!({"op":"setting","key":"clearCookiesOnQuit","value":true}));
    assert_eq!(commands(&r)[0], json!({"op":"preference","key":"clearCookiesOnQuit","value":true}));
    assert!(commands(&s.dispatch(json!({"op":"setting","key":"clearCookiesOnQuit","value":"yes"}))).is_empty());
    s.snapshot["preferences"]["clearCookiesOnQuit"] = json!(true);
    s.dispatch(json!({"op":"screen","value":"settings"}));
    let html = s.dispatch(json!({"op":"section","value":"privacy"}))["html"].as_str().unwrap().to_string();
    assert!(html.contains("Clear when Neutrino quits (1 on)"));
}
#[test]
fn downloads_show_progress_and_pause_or_resume() {
    let mut s = shell();
    s.snapshot["downloads"] = json!([
        {"id":"d1","name":"movie.mp4","status":"Downloading","complete":false,"fraction":0.4,"paused":false,"canPause":true},
        {"id":"d2","name":"notes.zip","status":"Paused","complete":false,"fraction":0.7,"paused":true,"canPause":true}]);
    s.dispatch(json!({"op":"screen","value":"library"}));
    let html = s.dispatch(json!({"op":"section","value":"downloads"}))["html"].as_str().unwrap().to_string();
    assert!(html.contains("data-action=\"downloadPause\" data-id=\"d1\"") && html.contains("data-action=\"downloadResume\" data-id=\"d2\""));
    assert!(html.contains("<progress class=\"download-progress\" max=\"1\" value=\"0.4\""));
    let r = s.dispatch(json!({"op":"native","action":"downloadPause","id":"d1"}));
    assert_eq!(commands(&r)[0]["op"], "downloadPause");
    s.snapshot["downloads"] = json!([{"id":"d3","name":"setup.dmg","status":"Cancelled","complete":false,"ended":true}]);
    let html = s.dispatch(json!({"op":"sync","snapshot":s.snapshot.clone()}))["html"].as_str().unwrap().to_string();
    assert!(!html.contains("downloadOpen") && !html.contains("downloadCancel") && html.contains("downloadRemove"));
}
#[test]
fn folders_nest_inside_folders_within_the_depth_limit() {
    let mut s = shell();
    s.snapshot["folders"] = json!([{"id":"f1","name":"Work"},{"id":"f2","name":"Projects","parentID":"f1"},{"id":"f3","name":"Alpha","parentID":"f2"},{"id":"f4","name":"Inbox"}]);
    s.snapshot["session"]["tabs"][1]["folderID"] = json!("f3");
    let html = s.dispatch(json!({"op":"sync","snapshot":s.snapshot.clone()}))["html"].as_str().unwrap().to_string();
    let at = |name: &str| html.find(&format!("<span>{name}</span>")).unwrap();
    assert!(at("Work") < at("Projects") && at("Projects") < at("Alpha") && html.contains("data-depth=\"2\""));
    // Projects (two levels) can't go into Alpha, which is inside it, and can move to the top.
    let menu = s.dispatch(json!({"op":"menu","value":"folder:f2"}))["html"].as_str().unwrap().to_string();
    assert!(menu.contains("data-parent=\"\"") && menu.contains("data-parent=\"f4\"") && !menu.contains("data-parent=\"f3\""));
    assert!(commands(&s.dispatch(json!({"op":"nest-folder","id":"f1","parent":"f3"}))).is_empty());
    assert!(s.notice.contains("can’t go inside one of its own folders"));
    assert_eq!(commands(&s.dispatch(json!({"op":"nest-folder","id":"f4","parent":"f3"})))[0], json!({"op":"nestFolder","id":"f4","parent":"f3"}));
    // Inbox inside Alpha would be a fourth level, so Alpha offers no new folder inside after it.
    s.snapshot["folders"][3]["parentID"] = json!("f3");
    s.dispatch(json!({"op":"sync","snapshot":s.snapshot.clone()}));
    let menu = s.dispatch(json!({"op":"menu","value":"folder:f4"}))["html"].as_str().unwrap().to_string();
    assert!(!menu.contains("new-folder:f4"));
    let normalized = neutrino_shell::core_request(json!({"op":"normalizeSpace","value":{"id":"s","name":"S","profileID":"p","tabs":[],"folders":[{"id":"a","name":"A","parentID":"b"},{"id":"b","name":"B","parentID":"a"},{"id":"c","name":"C","parentID":"gone"}]}})).unwrap();
    assert!(array_all_null(&normalized["folders"], "parentID"));
}
fn array_all_null(v: &Value, key: &str) -> bool {
    v.as_array().unwrap().iter().all(|f| f[key].is_null())
}
#[test]
fn passwords_import_from_chromium_family_browsers_only() {
    let mut s = shell();
    s.dispatch(json!({"op":"screen","value":"settings"}));
    let html = s.dispatch(json!({"op":"section","value":"passwords"}))["html"].as_str().unwrap().to_string();
    assert!(html.contains("data-op=\"browser-passwords\" data-value=\"arc\"") && !html.contains("data-op=\"browser-passwords\" data-value=\"safari\""));
    let r = s.dispatch(json!({"op":"browser-passwords","value":"brave"}));
    assert_eq!(commands(&r)[0], json!({"op":"importBrowserPasswords","value":"brave"}));
    assert!(commands(&s.dispatch(json!({"op":"browser-passwords","value":"firefox"}))).is_empty());
    s.snapshot["modules"] = json!([{"id":"org.neutrino.password-manager","capability":"feature","bundled":true,"installed":true,"enabled":false}]);
    assert!(commands(&s.dispatch(json!({"op":"browser-passwords","value":"brave"}))).is_empty());
}
#[test]
fn a_shortcut_in_use_moves_only_after_confirmation() {
    let mut s = shell();
    let r = s.dispatch(json!({"op":"shortcut","action":"new-window","value":"cmd+t"}));
    assert!(commands(&r).is_empty());
    let html = r["html"].as_str().unwrap();
    assert!(html.contains("is already the shortcut for New tab") && html.contains("data-confirm=\"true\""));
    let r = s.dispatch(json!({"op":"shortcut","action":"new-window","value":"cmd+t","confirm":"true"}));
    assert_eq!(commands(&r), &[json!({"op":"setShortcut","action":"new-tab","value":"none"}), json!({"op":"setShortcut","action":"new-window","value":"cmd+t"})]);
    assert!(s.menu.is_empty());
    let r = s.dispatch(json!({"op":"shortcut","action":"new-window","value":"ctrl+alt+k"}));
    assert_eq!(commands(&r), &[json!({"op":"setShortcut","action":"new-window","value":"ctrl+alt+k"})]);
}
#[test]
fn fake_my_history_sends_one_kind_of_visit() {
    let mut s = shell();
    let r = s.dispatch(json!({"op":"fake-history","value":"learning"}));
    let entries = commands(&r)[0]["entries"].as_array().unwrap().clone();
    assert_eq!(commands(&r)[0]["op"], "fakeHistory");
    assert!(entries.len() >= 6 && entries.iter().all(|e| e["url"].as_str().unwrap().starts_with("https://")));
    assert!(commands(&s.dispatch(json!({"op":"fake-history","value":"anything"}))).is_empty());
    s.snapshot["modules"] = json!([{"id":"org.neutrino.fake-history","capability":"feature","bundled":true,"installed":true,"enabled":false}]);
    assert!(commands(&s.dispatch(json!({"op":"fake-history","value":"learning"}))).is_empty());
}
#[test]
fn tab_search_lists_and_filters_open_tabs() {
    let mut s = shell();
    let html = s.dispatch(json!({"op":"menu","value":"tab-search"}))["html"].as_str().unwrap().to_string();
    assert!(html.contains("Search open tabs") && html.contains("data-op=\"selectTab\" data-id=\"a\"") && html.contains("data-op=\"selectTab\" data-id=\"c\""));
    let html = s.dispatch(json!({"op":"name","value":"example.com"}))["html"].as_str().unwrap().to_string();
    let menu = &html[html.find("popover-menu").unwrap()..];
    assert!(menu.contains("data-id=\"a\"") && !menu.contains("data-id=\"c\""));
    s.dispatch(json!({"op":"selectTab","id":"a"}));
    assert!(s.menu.is_empty());
}
#[test]
fn listed_sites_can_be_edited_from_privacy_settings() {
    let mut s = shell();
    s.snapshot["preferences"]["siteSettings"] = json!({"news.example":{"blockScripts":true,"camera":"block"}});
    s.dispatch(json!({"op":"screen","value":"settings"}));
    let html = s.dispatch(json!({"op":"section","value":"privacy"}))["html"].as_str().unwrap().to_string();
    assert!(html.contains("site-settings-row site-news-example") && html.contains("aria-label=\"Camera for news.example\""));
    let r = s.dispatch(json!({"op":"site-setting","host":"news.example","key":"camera","value":"allow"}));
    assert_eq!(commands(&r)[0], json!({"op":"siteSetting","host":"news.example","key":"camera","value":"allow"}));
    // A site not in the list can't be edited from here.
    assert!(commands(&s.dispatch(json!({"op":"site-setting","host":"other.example","key":"camera","value":"allow"}))).is_empty());
}
#[test]
fn reader_places_images_after_their_paragraph_and_reads_aloud() {
    let mut s = shell();
    s.snapshot["assistantResponse"] = json!("A title\n\nFirst   paragraph of the story, with more words.\n\nSecond paragraph follows here.");
    s.snapshot["readerImages"] = json!([
        {"src":"data:image/jpeg;base64,AAAA","alt":"A harbor","anchor":"First paragraph of the story"},
        {"src":"data:image/jpeg;base64,BBBB","alt":"","anchor":""},
        {"src":"https://tracker.example/x.png","alt":"remote","anchor":""}]);
    s.dispatch(json!({"op":"sync","snapshot":s.snapshot.clone()}));
    let html = s.dispatch(json!({"op":"screen","value":"reader"}))["html"].as_str().unwrap().to_string();
    let first = html.find("First").unwrap();
    let harbor = html.find("base64,AAAA").unwrap();
    assert!(first < harbor && harbor < html.find("Second paragraph").unwrap());
    assert!(html.find("base64,BBBB").unwrap() < first && !html.contains("tracker.example"));
    let r = s.dispatch(json!({"op":"reader-speak","value":"start"}));
    assert_eq!(commands(&r)[0], json!({"op":"readerSpeak","value":"start"}));
}
#[test]
fn boards_hold_page_captures() {
    let mut s = shell();
    s.snapshot["preferences"]["boards"] = json!([{"id":"b1","profileID":"p1","name":"Ideas","items":[
        {"id":"i1","kind":"image","title":"Alpha","url":"https://example.com/a","text":"","x":24,"y":24}]}]);
    s.snapshot["boardImages"] = json!({"i1":"data:image/jpeg;base64,QUJD"});
    s.dispatch(json!({"op":"screen","value":"library"}));
    let html = s.dispatch(json!({"op":"section","value":"boards"}))["html"].as_str().unwrap().to_string();
    assert!(html.contains("board-card image") && html.contains("src=\"data:image/jpeg;base64,QUJD\""));
    let r = s.dispatch(json!({"op":"board","value":"add-capture","board":"b1"}));
    assert_eq!(commands(&r)[0], json!({"op":"boardCapture","board":"b1"}));
    assert!(commands(&s.dispatch(json!({"op":"board","value":"add-capture","board":"missing"}))).is_empty());
}
#[test]
fn modules_added_by_updates_follow_the_layout_defaults() {
    let default = |id: &str, preset: &str| neutrino_shell::core_request(json!({"op":"moduleDefault","id":id,"preset":preset})).unwrap();
    assert_eq!(default("org.neutrino.fingerprinting", "brave"), json!(true));
    assert_eq!(default("org.neutrino.fingerprinting", "neutrino"), json!(false));
    assert_eq!(default("org.neutrino.fake-history", "gx"), json!(true));
    assert_eq!(default("org.neutrino.tab-sleep", "arc"), json!(true));
}
#[test]
fn captures_can_be_marked_up_before_saving() {
    let mut s = shell();
    s.dispatch(json!({"op":"capture-mode","value":"area-markup"}));
    assert!(s.capture_select && s.capture_markup);
    let r = s.dispatch(json!({"op":"capture-area","x":10,"y":10,"width":100,"height":80}));
    assert_eq!(commands(&r)[0]["markup"], json!(true));
    s.snapshot["markupImage"] = json!("data:image/png;base64,iVBORw0KGgo=");
    let r = s.dispatch(json!({"op":"sync","snapshot":s.snapshot.clone()}));
    assert!(r["html"].as_str().unwrap().contains("markup-canvas") && r["overlay"] == json!(true));
    let r = s.dispatch(json!({"op":"markup","value":"copy","data":"data:image/png;base64,QUJD"}));
    assert_eq!(commands(&r)[0], json!({"op":"markupSave","data":"data:image/png;base64,QUJD","copy":true}));
    assert!(commands(&s.dispatch(json!({"op":"markup","value":"save","data":"javascript:alert(1)"}))).is_empty());
}
#[test]
fn new_tab_follows_the_chosen_browser() {
    let mut s = shell();
    // Neutrino and Arc ask in the command bar.
    s.dispatch(json!({"op":"newTab"}));
    assert!(s.palette);
    s.dispatch(json!({"op":"escape"}));
    for preset in ["chrome", "safari", "brave", "gx", "vivaldi"] {
        s.snapshot["configuration"]["theme"]["preset"] = json!(preset);
        let r = s.dispatch(json!({"op":"newTab"}));
        assert!(!s.palette, "{preset}");
        assert_eq!(commands(&r), &[json!({"op":"newTab","parentID":null})]);
        assert_eq!(r["focus"], "address-input");
    }
    // The empty tab is listed, and its start page's search box is the address field.
    s.snapshot["session"]["tabs"].as_array_mut().unwrap().push(json!({"id":"n","title":"New tab","pinned":false}));
    s.snapshot["session"]["selectedTabID"] = json!("n");
    s.snapshot["configuration"]["theme"]["preset"] = json!("chrome");
    let html = s.dispatch(json!({"op":"sync","snapshot":s.snapshot.clone()}))["html"].as_str().unwrap().to_string();
    assert!(html.contains(r#"data-tab="n""#) && html.contains(r#"class="start-search" data-op="focus-address""#));
    s.snapshot["configuration"]["theme"]["preset"] = json!("arc");
    let html = s.dispatch(json!({"op":"sync","snapshot":s.snapshot.clone()}))["html"].as_str().unwrap().to_string();
    assert!(!html.contains(r#"data-tab="n""#));
}
#[test]
fn a_tab_dragged_onto_the_page_can_open_in_split_view() {
    let mut s = shell();
    // With no other page open there is nothing to show beside this one.
    let html = s.dispatch(json!({"op":"sync","snapshot":s.snapshot.clone()}))["html"].as_str().unwrap().to_string();
    assert!(!html.contains("split-drop"));
    s.snapshot["session"]["tabs"][2]["url"] = json!("https://example.com/c");
    let html = s.dispatch(json!({"op":"sync","snapshot":s.snapshot.clone()}))["html"].as_str().unwrap().to_string();
    assert!(html.contains(r#"class="split-drop" data-current="a""#));
    // Only a tab with a page can join, and never the current one.
    assert!(commands(&s.dispatch(json!({"op":"split-with","id":"a"}))).is_empty());
    assert!(commands(&s.dispatch(json!({"op":"split-with","id":"b"}))).is_empty());
    assert_eq!(commands(&s.dispatch(json!({"op":"split-with","id":"c"})))[0], json!({"op":"splitWith","id":"c"}));
    s.snapshot["session"]["split"] = json!({"first":"a","second":"c"});
    let html = s.dispatch(json!({"op":"sync","snapshot":s.snapshot.clone()}))["html"].as_str().unwrap().to_string();
    assert!(!html.contains("split-drop"));
}
#[test]
fn brave_start_page_counts_every_block_and_the_time_saved() {
    let mut s = shell();
    s.snapshot["configuration"]["theme"]["preset"] = json!("brave");
    s.snapshot["session"]["selectedTabID"] = json!("b");
    s.snapshot["preferences"]["startPage"] = json!({"stats": true});
    s.snapshot["shieldsStats"] = json!({"blocked": 12, "lifetime": 90_000});
    let html = s.dispatch(json!({"op":"sync","snapshot":s.snapshot.clone()}))["html"].as_str().unwrap().to_string();
    assert!(html.contains("<strong>90000</strong><small>Trackers &amp; ads blocked</small>"), "{html}");
    assert!(html.contains("<strong>1 hour</strong><small>Estimated time saved</small>"));
}
#[test]
fn named_themes_bring_their_window_colors() {
    let mut s = shell();
    s.dispatch(json!({"op":"screen","value":"editor"}));
    s.dispatch(json!({"op":"editor-value","key":"themePack","value":"Hackerman"}));
    let theme = &s.draft.as_ref().unwrap()["theme"];
    assert_eq!((theme["accentHex"].as_str(), theme["colorMode"].as_str(), theme["surfaceHex"].as_str()), (Some("1ed760"), Some("dark"), Some("0d1910")));
    // Vivaldi's own theme keeps the light window.
    s.dispatch(json!({"op":"editor-value","key":"themePack","value":"Vivaldi"}));
    assert!(s.draft.as_ref().unwrap()["theme"]["surfaceHex"].is_null());
    s.dispatch(json!({"op":"editor-value","key":"themePack","value":"Not a theme"}));
    assert_eq!(s.draft.as_ref().unwrap()["theme"]["themePack"], "Vivaldi");
}
#[test]
fn permission_defaults_can_refuse_every_request() {
    let mut s = shell();
    let r = s.dispatch(json!({"op":"setting","key":"blockLocation","value":true}));
    assert_eq!(commands(&r)[0], json!({"op":"preference","key":"blockLocation","value":true}));
    assert!(commands(&s.dispatch(json!({"op":"setting","key":"blockLocation","value":"yes"}))).is_empty());
    s.snapshot["preferences"]["blockCamera"] = json!(true);
    s.dispatch(json!({"op":"sync","snapshot":s.snapshot.clone()}));
    let html = s.dispatch(json!({"op":"screen","value":"settings","section":"privacy"}))["html"].as_str().unwrap().to_string();
    assert!(html.contains("Permission defaults (1 blocked)") && html.contains("Block notification requests"));
}
#[test]
fn a_payment_form_offers_saved_cards() {
    let mut s = shell();
    s.snapshot["cards"] = json!([{"id":"k1","name":"Ada","last4":"1111","expiry":"12/30"}]);
    s.snapshot["cardOffer"] = json!(true);
    let html = s.dispatch(json!({"op":"sync","snapshot":s.snapshot.clone()}))["html"].as_str().unwrap().to_string();
    assert!(html.contains("Fill a saved card on this page?") && html.contains("page-frame with-prompt") && html.contains("Ada ····1111"));
    assert_eq!(commands(&s.dispatch(json!({"op":"card","value":"fill","id":"k1"})))[0], json!({"op":"fillCard","id":"k1"}));
    assert_eq!(commands(&s.dispatch(json!({"op":"card","value":"dismiss-offer"})))[0], json!({"op":"cardOfferDismiss"}));
    // No saved card, no offer; a save-password question takes the bar first.
    s.snapshot["passwordPrompt"] = json!({"origin":"https://example.com","username":"a"});
    let html = s.dispatch(json!({"op":"sync","snapshot":s.snapshot.clone()}))["html"].as_str().unwrap().to_string();
    assert!(!html.contains("Fill a saved card"));
}
#[test]
fn customize_reorders_toolbar_buttons_and_removes_built_ins() {
    let mut s = shell();
    s.dispatch(json!({"op":"screen","value":"editor"}));
    s.dispatch(json!({"op":"editor-value","key":"toolbarItems","value":["home","reader","capture"]}));
    let html = s.dispatch(json!({"op":"sync","snapshot":s.snapshot.clone()}))["html"].as_str().unwrap().to_string();
    assert!(html.contains("Move Reader view earlier") && html.contains(r#"data-json="[&quot;reader&quot;,&quot;home&quot;,&quot;capture&quot;]""#));
    s.dispatch(json!({"op":"editor-value","key":"hiddenButtons","value":["reload","forward"]}));
    assert!(commands(&s.dispatch(json!({"op":"editor-value","key":"hiddenButtons","value":["back"]}))).is_empty());
    assert_eq!(s.draft.as_ref().unwrap()["layout"]["hiddenButtons"], json!(["reload","forward"]));
    let html = s.dispatch(json!({"op":"sync","snapshot":s.snapshot.clone()}))["html"].as_str().unwrap().to_string();
    let preview = &html[html.find("rail-navigation").unwrap()..];
    let nav = &preview[..preview.find("</div>").unwrap()];
    assert!(nav.contains(r#"data-op="back""#) && !nav.contains(r#"data-op="reload""#) && !nav.contains(r#"data-op="forward""#));
}
#[test]
fn speed_dial_groups_are_folders_inside_speed_dial() {
    let mut s = shell();
    s.snapshot["configuration"]["theme"]["preset"] = json!("vivaldi");
    s.snapshot["session"]["selectedTabID"] = json!("b");
    s.snapshot["features"] = json!({"speed-dial": true});
    s.snapshot["bookmarkIndex"] = json!([
        {"id":"d1","title":"Mail","url":"https://mail.example/","folder":"Speed Dial"},
        {"id":"d2","title":"Tracker","url":"https://tracker.example/","folder":"Speed Dial/Work"}]);
    let html = s.dispatch(json!({"op":"sync","snapshot":s.snapshot.clone()}))["html"].as_str().unwrap().to_string();
    assert!(html.contains(r#"data-op="dial-group" data-value="Work""#) && html.contains("Mail") && !html.contains("Tracker"));
    let html = s.dispatch(json!({"op":"dial-group","value":"Work"}))["html"].as_str().unwrap().to_string();
    assert!(html.contains("Tracker") && !html.contains(">Mail<"));
    // A new group starts empty, without top sites, and new tiles go into its folder.
    s.dispatch(json!({"op":"menu","value":"new-dial-group"}));
    s.dispatch(json!({"op":"name","value":"Reading"}));
    s.dispatch(json!({"op":"dial-group","value":"new"}));
    assert_eq!(s.dial_group, "Reading");
    s.dispatch(json!({"op":"menu","value":"add-site:dial"}));
    s.dispatch(json!({"op":"name","value":"news.example"}));
    let r = s.dispatch(json!({"op":"addSite"}));
    assert_eq!(commands(&r)[0]["folder"], "Speed Dial/Reading");
    assert!(s.dispatch(json!({"op":"dial-group","value":"Nope"})).is_object() && s.dial_group == "Reading");
}
#[test]
fn expired_payment_cards_are_refused() {
    let mut s = shell();
    s.snapshot["now"] = json!(813_000_000.0); // 6 October 2026
    let r = s.dispatch(json!({"op":"card","value":"save","name":"Ada","number":"4111 1111 1111 1111","expiry":"09/26"}));
    assert!(commands(&r).is_empty() && s.notice.contains("expired"));
    let r = s.dispatch(json!({"op":"card","value":"save","name":"Ada","number":"4111 1111 1111 1111","expiry":"10/26"}));
    assert_eq!(commands(&r)[0]["op"], "saveCard");
}
#[test]
fn closing_palette_restores_page_identity() {
    let mut s = shell();
    s.dispatch(json!({"op":"palette"}));
    s.dispatch(json!({"op":"query","value":"https://wrong.example"}));
    let r = s.dispatch(json!({"op":"escape"}));
    assert!(!s.palette);
    assert_eq!(s.active()["url"], "https://example.com/a");
    assert!(!r["html"]
        .as_str()
        .unwrap()
        .contains("https://wrong.example"));
}
#[test]
fn freeze_blocks_platform_mutations() {
    let mut s = shell();
    s.snapshot["frozen"] = json!(true);
    for op in [
        "newTab",
        "closeTab",
        "finishSetup",
        "clearHistory",
        "saveAI",
    ] {
        assert!(commands(&s.dispatch(json!({"op":op,"id":"a"}))).is_empty());
    }
}
#[test]
fn malformed_ffi_requests_return_owned_errors() {
    use std::ffi::{CStr, CString};
    unsafe {
        let shell = neutrino_shell::neutrino_shell_new();
        for input in ["{", "null", "[]"] {
            let input = CString::new(input).unwrap();
            let output = neutrino_shell::neutrino_shell_dispatch(shell, input.as_ptr());
            assert!(!output.is_null());
            assert!(
                serde_json::from_str::<Value>(CStr::from_ptr(output).to_str().unwrap()).is_ok()
            );
            neutrino_shell::neutrino_string_free(output);
        }
        neutrino_shell::neutrino_shell_free(shell);
    }
}
#[test]
fn every_editor_exit_requires_a_decision_and_redo_replays_the_change() {
    for request in [
        json!({"op":"newTab"}),
        json!({"op":"screen","value":"settings"}),
        json!({"op":"palette"}),
        json!({"op":"switchSpace","id":"s2"}),
    ] {
        let mut s = shell();
        s.dispatch(json!({"op":"screen","value":"editor"}));
        s.dispatch(json!({"op":"dock","component":"tabs","region":"trailing"}));
        assert!(commands(&s.dispatch(request.clone())).is_empty());
        assert_eq!(s.menu, "discard-editor");
        assert_eq!(s.screen, "editor");
        s.dispatch(json!({"op":"editor-cancel"}));
        assert!(s.draft.is_none());
        assert_ne!(s.screen, "editor");
        assert!(s.pending_exit.is_none());
    }
    let mut s = shell();
    s.dispatch(json!({"op":"screen","value":"editor"}));
    s.dispatch(json!({"op":"dock","component":"tabs","region":"trailing"}));
    s.dispatch(json!({"op":"dock","component":"tabs","region":"bottom"}));
    s.dispatch(json!({"op":"editor-undo"}));
    assert_eq!(s.config()["layout"]["tabs"], "trailing");
    s.dispatch(json!({"op":"editor-redo"}));
    assert_eq!(s.config()["layout"]["tabs"], "bottom");
}
#[test]
fn page_error_does_not_mount_a_view_over_recovery() {
    let mut s = shell();
    s.snapshot["pageError"] = json!("offline");
    let snapshot = s.snapshot.clone();
    let r = s.dispatch(json!({"op":"sync","snapshot":snapshot}));
    let html = r["html"].as_str().unwrap();
    assert!(html.contains("Try again"));
    assert!(!html.contains("class=\"native-page\""));
}
#[test]
fn private_notes_cannot_mutate_the_regular_profile() {
    let mut s = shell();
    s.snapshot["private"] = json!(true);
    for action in ["createNote", "saveNote", "deleteNote"] {
        assert!(commands(&s.dispatch(
            json!({"op":"native","action":action,"id":"note","value":{"text":"secret"}})
        ))
        .is_empty());
    }
}
#[test]
fn provider_endpoint_cannot_change_host_between_parsers() {
    use neutrino_shell::core_request;
    for endpoint in [
        "https://api.openai.com\\@attacker.example/v1",
        "https://api.openai.com@attacker.example/v1",
        " https://api.openai.com/v1",
        "https://api.openai.com/v1\n",
    ] {
        assert!(core_request(
            json!({"op":"validateAI","provider":"openAI","endpoint":endpoint,"model":"m"})
        )
        .is_err());
    }
    let endpoint=core_request(json!({"op":"validateAI","provider":"openAI","endpoint":"HTTPS://API.OPENAI.COM:443/v1","model":"m"})).unwrap();
    assert_eq!(endpoint, "https://api.openai.com/v1");
}
#[test]
fn undo_feedback_is_attached_only_to_the_tab_move() {
    let mut s = shell();
    s.dispatch(json!({"op":"move-tab","id":"a","group":"pinned"}));
    s.dispatch(json!({"op":"screen","value":"editor"}));
    s.dispatch(json!({"op":"editor-save"}));
    let r = s.dispatch(json!({"op":"editor-result","action":"applyConfiguration","success":true}));
    assert!(r["html"].as_str().unwrap().contains("Appearance saved."));
    assert!(!r["html"]
        .as_str()
        .unwrap()
        .contains("Appearance saved.</span><button data-op=\"undo-tabs\""));
}
#[test]
fn split_error_keeps_the_healthy_pane_visible() {
    let mut s = shell();
    s.snapshot["session"]["split"] = json!({"first":"a","second":"b"});
    s.snapshot["pageError"] = json!("offline");
    s.snapshot["pageErrors"] = json!({"a":"offline"});
    let snapshot = s.snapshot.clone();
    let r = s.dispatch(json!({"op":"sync","snapshot":snapshot}));
    let html = r["html"].as_str().unwrap();
    assert!(html.contains("data-page=\"b\""));
    assert!(!html.contains("data-page=\"a\""));
    assert!(html.contains("Exit split view"));
}
#[test]
fn auxiliary_downloads_have_no_library_or_browser_capability() {
    let mut s = shell();
    s.dispatch(json!({"op":"sync","snapshot":{"downloadsWindow":true,"completedOnboarding":true,"private":true,"downloads":[]}}));
    for request in [
        json!({"op":"section","value":"notes"}),
        json!({"op":"native","action":"createNote"}),
        json!({"op":"screen","value":"settings"}),
        json!({"op":"newTab"}),
    ] {
        let r = s.dispatch(request);
        assert!(commands(&r).is_empty());
        let html = r["html"].as_str().unwrap();
        assert!(html.contains("downloads-window"));
        assert!(!html.contains("Library sections"));
        assert!(!html.contains("workspace-rail"));
    }
}
#[test]
fn keep_editing_forgets_the_cancelled_exit_and_save_completes_the_new_one() {
    let mut s = shell();
    s.dispatch(json!({"op":"screen","value":"editor"}));
    s.dispatch(json!({"op":"dock","component":"tabs","region":"trailing"}));
    s.dispatch(json!({"op":"screen","value":"settings"}));
    s.dispatch(json!({"op":"escape"}));
    assert!(s.pending_exit.is_none());
    s.dispatch(json!({"op":"escape"}));
    s.dispatch(json!({"op":"editor-cancel"}));
    assert_eq!(s.screen, "browse");
    s.dispatch(json!({"op":"screen","value":"editor"}));
    s.dispatch(json!({"op":"dock","component":"tabs","region":"trailing"}));
    s.dispatch(json!({"op":"screen","value":"settings"}));
    let r = s.dispatch(json!({"op":"editor-save"}));
    assert_eq!(commands(&r)[0]["op"], "applyConfiguration");
    assert_eq!(s.screen, "editor");
    s.dispatch(json!({"op":"editor-result","action":"applyConfiguration","success":true}));
    assert_eq!(s.screen, "settings");
    assert!(s.draft.is_none());
}

#[test]
fn global_search_reveals_results_but_cancel_returns_to_settings() {
    let mut s = shell();
    s.dispatch(json!({"op":"screen","value":"settings"}));
    s.dispatch(json!({"op":"palette"}));
    s.dispatch(json!({"op":"escape"}));
    assert_eq!(s.screen, "settings");
    s.dispatch(json!({"op":"palette","value":"Alpha"}));
    let results = s.results();
    let index = results.iter().position(|r| r["kind"] == "tab").unwrap();
    let r = s.dispatch(json!({"op":"select-result","index":index}));
    assert_eq!(commands(&r)[0]["op"], "selectTab");
    assert_eq!(s.screen, "browse");
    s.dispatch(json!({"op":"screen","value":"settings"}));
    s.dispatch(json!({"op":"navigate","value":"https://example.org"}));
    assert_eq!(s.screen, "browse");
    s.dispatch(json!({"op":"screen","value":"library"}));
    s.sidebar_hidden = true;
    s.snapshot["configuration"]["layout"]["secondaryPanel"] = json!("notes");
    s.dispatch(json!({"op":"reveal-workspace"}));
    assert!(s.panel_key().is_empty());
    assert_eq!(s.screen, "browse");
    assert!(!s.sidebar_hidden);
}

#[test]
fn continuous_width_drag_is_one_undo_step_despite_passive_updates() {
    let mut s = shell();
    s.dispatch(json!({"op":"screen","value":"editor"}));
    for width in [250, 280, 310] {
        s.dispatch(json!({"op":"editor-value","key":"tabsWidth","value":width,"gesture":"drag-1"}));
        s.dispatch(json!({"op":"sync","snapshot":s.snapshot.clone()}));
    }
    assert_eq!(s.config()["layout"]["tabsWidth"], 310);
    s.dispatch(json!({"op":"editor-end-adjustment"}));
    s.dispatch(json!({"op":"editor-undo"}));
    assert_eq!(s.config()["layout"]["tabsWidth"], 240);
    s.dispatch(json!({"op":"editor-redo"}));
    assert_eq!(s.config()["layout"]["tabsWidth"], 310);
    s.dispatch(json!({"op":"editor-value","key":"tabsWidth","value":300,"gesture":"drag-2"}));
    s.dispatch(json!({"op":"editor-end-adjustment"}));
    s.dispatch(json!({"op":"editor-undo"}));
    assert_eq!(s.config()["layout"]["tabsWidth"], 310);
}

#[test]
fn command_tab_creation_is_deferred_and_cancel_preserves_the_live_page() {
    let mut s = shell();
    let before = s.snapshot["session"].clone();
    let r = s.dispatch(json!({"op":"newTab"}));
    assert!(commands(&r).is_empty());
    assert!(s.palette);
    assert_eq!(r["focus"], "command-input");
    s.dispatch(json!({"op":"escape"}));
    assert_eq!(s.snapshot["session"], before);
    s.dispatch(json!({"op":"newTab"}));
    s.dispatch(json!({"op":"query","value":"https://example.org/research"}));
    let r = s.dispatch(json!({"op":"activate-result"}));
    assert_eq!(commands(&r).len(), 1);
    assert_eq!(commands(&r)[0]["op"], "newTab");
    assert_eq!(commands(&r)[0]["url"], "https://example.org/research");
    s.dispatch(json!({"op":"palette","value":"Modules"}));
    assert_eq!(s.results()[0]["kind"], "command");
    s.dispatch(json!({"op":"activate-result"}));
    assert_eq!(s.screen, "modules");
}

#[test]
fn space_gestures_and_reordering_stay_within_the_current_profile() {
    let mut s = shell();
    let r = s.dispatch(json!({"op":"space-step","value":1}));
    assert_eq!(commands(&r)[0]["id"], "s2");
    s.snapshot["session"]["spaceID"] = json!("s2");
    assert!(commands(&s.dispatch(json!({"op":"space-step","value":1}))).is_empty());
    let r = s.dispatch(json!({"op":"reorder-spaces","id":"s2","before":"s1"}));
    assert_eq!(commands(&r)[0]["ids"], json!(["s2", "s1"]));
    assert!(
        commands(&s.dispatch(json!({"op":"reorder-spaces","id":"secret","before":"s1"})))
            .is_empty()
    );
    let r = s.dispatch(json!({"op":"undo-tabs"}));
    assert_eq!(commands(&r)[0]["ids"], json!(["s1", "s2"]));
    s.snapshot["private"] = json!(true);
    assert!(commands(&s.dispatch(json!({"op":"space-step","value":-1}))).is_empty());
    assert!(
        commands(&s.dispatch(json!({"op":"reorder-spaces","id":"s2","before":"s1"}))).is_empty()
    );
}

#[test]
fn module_settings_require_a_real_installed_module_and_declared_field() {
    let mut s = shell();
    s.snapshot["modules"] = json!([{"id":"org.neutrino.notes","name":"Notes","installed":true,"enabled":true,"settings":[{"id":"defaultTitle","kind":"text","value":"Untitled"}]}]);
    let r=s.dispatch(json!({"op":"module-setting","id":"org.neutrino.notes","key":"defaultTitle","value":"Project notes"}));
    assert_eq!(commands(&r)[0]["op"], "setModuleSetting");
    assert_eq!(commands(&r)[0]["value"], "Project notes");
    assert!(commands(&s.dispatch(
        json!({"op":"module-setting","id":"unknown","key":"defaultTitle","value":"bad"})
    ))
    .is_empty());
    assert!(commands(&s.dispatch(
        json!({"op":"module-setting","id":"org.neutrino.notes","key":"undeclared","value":"bad"})
    ))
    .is_empty());
    s.snapshot["modules"][0]["installed"] = json!(false);
    assert!(commands(&s.dispatch(
        json!({"op":"module-setting","id":"org.neutrino.notes","key":"defaultTitle","value":"bad"})
    ))
    .is_empty());
}

#[test]
fn utility_pages_preserve_browser_tools_and_routine_menus_are_nonmodal() {
    let mut s = shell();
    let r = s.dispatch(json!({"op":"screen","value":"modules"}));
    let html = r["html"].as_str().unwrap();
    assert!(html.contains("rail-dock"));
    assert!(html.contains("data-screen=\"modules\""));
    assert!(!html.contains("screen-scrim"));
    s.dispatch(json!({"op":"screen","value":"browse"}));
    let r = s.dispatch(json!({"op":"menu","value":"browser"}));
    assert_eq!(r["overlay"], false);
    assert!(r["html"].as_str().unwrap().contains("aria-modal=\"false\""));
    let r = s.dispatch(json!({"op":"menu","value":"clear-history"}));
    assert_eq!(r["overlay"], true);
}

#[test]
fn focus_recovers_after_overlays_and_address_focus_and_spaces_stay_in_profile() {
    let mut s = shell();
    s.snapshot["focusMode"] = json!(true);
    s.screen = "modules".into();
    s.dispatch(json!({"op":"palette"}));
    assert!(commands(&s.dispatch(json!({"op":"escape"}))).is_empty());
    assert_eq!(
        commands(&s.dispatch(json!({"op":"escape"})))[0]["op"],
        "exitFocus"
    );
    let address = s.dispatch(json!({"op":"focus-address"}));
    assert_eq!(address["focus"], "address-input");
    assert_eq!(commands(&address)[0]["op"], "exitFocus");
    assert!(commands(&s.dispatch(json!({"op":"switchSpace","id":"secret"}))).is_empty());
    assert_eq!(
        commands(&s.dispatch(json!({"op":"switchSpace","id":"s2"})))[0]["id"],
        "s2"
    );
}

#[test]
fn presets_and_saved_panel_edits_produce_real_browsing_surfaces() {
    let mut s = shell();
    s.dispatch(json!({"op":"screen","value":"editor"}));
    s.dispatch(json!({"op":"editor-preset","value":"chrome"}));
    assert_eq!(s.config()["layout"]["tabs"], "top");
    s.dispatch(json!({"op":"editor-preset","value":"neutrino"}));
    s.dispatch(json!({"op":"dock","component":"panels","region":"trailing"}));
    s.dispatch(json!({"op":"editor-value","key":"iconPack","value":"precision"}));
    s.dispatch(json!({"op":"editor-value","key":"cornerRadius","value":12.0}));
    let result = s.dispatch(json!({"op":"editor-save"}));
    let c = commands(&result)[0]["configuration"].clone();
    assert_eq!(c["layout"]["secondaryPanel"], "bookmarks");
    assert_eq!(c["theme"]["iconPack"], "precision");
    s.snapshot["configuration"] = c;
    let r = s.dispatch(json!({"op":"sync","snapshot":s.snapshot}));
    assert!(r["html"].as_str().unwrap().contains("workspace-panel"));
    assert!(r["html"]
        .as_str()
        .unwrap()
        .contains("--component-radius:12px"));
}
#[test]
fn svg_packages_cannot_import_markup_or_external_resources() {
    use neutrino_shell::core_request;
    assert!(
        core_request(json!({"op":"validateSVGIcons","icons":{"back":"M15 4 7 12l8 8"}})).is_ok()
    );
    for path in [
        "<svg onload=alert(1)>",
        "https://example.com/x.svg",
        "url(#icon)",
        "M0 0<script>",
    ] {
        assert!(core_request(json!({"op":"validateSVGIcons","icons":{"back":path}})).is_err());
    }
}
#[test]
fn full_uninstall_scope_excludes_other_apps_downloads_and_publisher_keys() {
    use neutrino_shell::core_request;
    let result=core_request(json!({"op":"uninstallPaths","home":"/Users/researcher","dataDirectory":"/Users/researcher/Library/Application Support/org.neutrino.browser"})).unwrap();
    assert_eq!(result.as_array().unwrap().len(), 7);
    assert!(!result.to_string().contains("Downloads"));
    assert!(
        core_request(json!({"op":"uninstallPaths","home":"/","dataDirectory":"/Library"})).is_err()
    );
    assert!(core_request(json!({"op":"uninstallPaths","home":"/Users/researcher","dataDirectory":"/Users/researcher"})).is_err());
    for service in [
        "org.neutrino.browser.passwords.anything",
        "org.neutrino.browser.other",
        "Sparkle Private Key",
        "org.brave.browser.passwords",
    ] {
        assert_eq!(
            core_request(json!({"op":"uninstallKeychainService","service":service})).unwrap(),
            false
        );
    }
}

#[test]
fn named_setups_have_a_complete_lifecycle_and_space_recovery() {
    use neutrino_shell::core_request;
    let config = neutrino_shell::core_request(json!({"op":"appearancePreset","id":"arc"})).unwrap();
    let mut library = json!({"preferences":{"savedConfigurations":[]},"spaces":[]});
    library=core_request(json!({"op":"manageNamedSetup","action":"save","name":"Research","configuration":config,"requirements":["org.neutrino.notes"],"value":library})).unwrap();
    let id = library["preferences"]["savedConfigurations"][0]["id"].clone();
    library["spaces"] = json!([{"setupID":id}]);
    library = core_request(
        json!({"op":"manageNamedSetup","action":"rename","id":id,"name":"Reading","value":library}),
    )
    .unwrap();
    assert_eq!(
        library["preferences"]["savedConfigurations"][0]["name"],
        "Reading"
    );
    let chrome = core_request(json!({"op":"appearancePreset","id":"chrome"})).unwrap();
    library=core_request(json!({"op":"manageNamedSetup","action":"replace","id":id,"configuration":chrome,"requirements":[],"value":library})).unwrap();
    assert_eq!(library["preferences"]["savedConfigurations"][0]["id"], id);
    assert_eq!(
        library["preferences"]["savedConfigurations"][0]["configuration"]["layout"]["tabs"],
        "top"
    );
    let mut full = library.clone();
    full["preferences"]["savedConfigurations"] =
        json!(vec![
            full["preferences"]["savedConfigurations"][0].clone();
            50
        ]);
    assert!(core_request(json!({"op":"manageNamedSetup","action":"save","name":"Overflow","configuration":config,"value":full})).is_err());
    library =
        core_request(json!({"op":"manageNamedSetup","action":"delete","id":id,"value":library}))
            .unwrap();
    assert!(library["spaces"][0]["setupID"].is_null());
    assert_eq!(library["preferences"]["savedConfigurations"], json!([]));
    assert!(core_request(
        json!({"op":"manageNamedSetup","action":"rename","id":id,"name":"Gone","value":library})
    )
    .is_err());
}
#[test]
fn module_recovery_reclaims_only_recognized_orphan_transaction_directories() {
    let root = std::env::temp_dir().join(format!("neutrino-orphan-{}", uuid::Uuid::new_v4()));
    let container = root;
    let root = container.join("Modules");
    std::fs::create_dir_all(&root).unwrap();
    let mut orphans = vec![];
    for prefix in [".stage-", ".backup-", ".restore-", ".batch-", ".write-"] {
        let p = root.join(format!("{prefix}{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&p).unwrap();
        std::fs::write(p.join("payload"), "orphan").unwrap();
        orphans.push(p);
    }
    let unrelated = root.join(".stage-user-export");
    std::fs::create_dir(&unrelated).unwrap();
    let result = neutrino_shell::core_request(
        json!({"op":"moduleRepository","action":"initialize","root":root}),
    )
    .unwrap();
    assert!(result["error"].is_null(), "{result}");
    assert!(orphans.iter().all(|p| !p.exists()));
    assert!(unrelated.exists());
    std::fs::remove_dir_all(container).unwrap();
}

#[test]
fn rejected_editor_saves_keep_drafts_and_named_input_until_acknowledged() {
    let mut s = shell();
    s.dispatch(json!({"op":"screen","value":"editor"}));
    s.dispatch(json!({"op":"editor-preset","value":"chrome"}));
    let draft = s.draft.clone();
    s.dispatch(json!({"op":"name","value":"Research"}));
    let r = s.dispatch(json!({"op":"editor-save-named"}));
    assert_eq!(commands(&r)[0]["op"], "saveNamedSetup");
    assert!(!s.notice.contains("saved"));
    s.dispatch(json!({"op":"editor-result","action":"saveNamedSetup","success":false,"message":"Use a name."}));
    assert_eq!(s.name, "Research");
    assert_eq!(s.draft, draft);
    assert_eq!(s.notice, "Use a name.");
    s.dispatch(json!({"op":"editor-save"}));
    s.dispatch(json!({"op":"editor-result","action":"applyConfiguration","success":false,"message":"Approval cancelled."}));
    assert_eq!(s.screen, "editor");
    assert_eq!(s.draft, draft);
}
#[test]
fn note_search_is_profile_and_space_scoped_with_newest_first() {
    let notes = json!([
        {"id":"old","profileID":"p1","spaceID":"s1","title":"Rust","modifiedAt":1},
        {"id":"new","profileID":"p1","spaceID":"s1","title":"Arc","sourceURL":"https://docs.rs/a","modifiedAt":5},
        {"id":"other","profileID":"p1","spaceID":"s2","title":"Rust","modifiedAt":7},
        {"id":"secret","profileID":"p2","spaceID":"s1","title":"Rust","modifiedAt":9}
    ]);
    let project = |all, query| {
        neutrino_shell::core_request(json!({"op":"projectNotes","value":notes,"profileID":"p1","spaceID":"s1","all":all,"query":query})).unwrap()
    };
    assert_eq!(project(false, ""), json!(["new", "old"]));
    assert_eq!(project(true, "RUST"), json!(["other", "old"]));
    assert_eq!(project(false, "docs.rs"), json!(["new"]));
}

#[test]
fn note_content_matches_remain_scoped_and_excerpts_distinguish_same_source() {
    let notes = json!([
        {"id":"one","profileID":"p1","spaceID":"s1","title":"An article","sourceURL":"https://example.org","excerpt":"First quotation","contentMatch":true},
        {"id":"two","profileID":"p1","spaceID":"s1","title":"An article","sourceURL":"https://example.org","excerpt":"Second quotation","contentMatch":false},
        {"id":"away","profileID":"p1","spaceID":"s2","contentMatch":true},
        {"id":"secret","profileID":"p2","spaceID":"s1","contentMatch":true}
    ]);
    let project = |all| neutrino_shell::core_request(json!({"op":"projectNotes","value":notes,"profileID":"p1","spaceID":"s1","all":all,"query":"phrase in body"})).unwrap();
    assert_eq!(project(false), json!(["one"]));
    assert_eq!(project(true), json!(["away", "one"]));
    let mut s = shell();
    s.snapshot["notes"] = json!([notes[0], notes[1]]);
    s.snapshot["selectedNote"] = json!({"id":"one","title":"An article","excerpt":"First quotation","quotedText":"First quotation","text":"draft"});
    let r = s.dispatch(json!({"op":"section","value":"notes"}));
    let html = r["html"].as_str().unwrap();
    assert!(html.contains("First quotation") && html.contains("Second quotation"));
    assert!(html.contains("note-quotation quote-one") && html.contains("Note actions"));
    assert!(!html.contains("Saved as you type"));
    for reference in html.split("href=\"#glyph-").skip(1) {
        let name = reference.split('"').next().unwrap();
        assert!(html.contains(&format!("id=\"glyph-{name}\"")), "Unresolved icon: {name}");
    }
    s.dispatch(json!({"op":"menu","value":"notes-scope"}));
    let scope = s.dispatch(json!({"op":"native","action":"notesScope","value":"all"}));
    assert_eq!(commands(&scope)[0]["op"], "notesScope");
    assert!(s.menu.is_empty());
    assert_eq!(scope["focus"], "notes-scope-trigger");
    s.dispatch(json!({"op":"menu","value":"notes-scope"}));
    assert_eq!(s.dispatch(json!({"op":"escape","restoreFocus":true}))["focus"], "notes-scope-trigger");
    s.dispatch(json!({"op":"menu","value":"notes-scope"}));
    assert_eq!(s.dispatch(json!({"op":"escape"}))["focus"], "");
}

#[test]
fn borrowed_note_search_handles_unicode_whitespace_nuls_and_bounds() {
    let search = |text: &[u8], query: &[u8]| unsafe {
        neutrino_shell::neutrino_text_contains(text.as_ptr().cast(), text.len(), query.as_ptr().cast(), query.len())
    };
    assert!(search("ÜBER\n  source\t漢字\0 preserved".as_bytes(), "über source 漢字".as_bytes()));
    assert!(search(b"before\0after", b"after"));
    assert!(!search(b"quotation", b"missing"));
    assert!(!search(&[0xff], b"anything"));
    assert!(!search(b"anything", &vec![b'x'; 1025]));
    assert!(!search(&vec![b'x'; 1_048_577], b"x"));
    let body = format!("{}needle at the end", "漢".repeat(200_000));
    assert!(search(body.as_bytes(), b"NEEDLE AT THE END"));
}

#[test]
fn crashed_receipt_writes_do_not_block_future_package_transactions() {
    let root = std::env::temp_dir().join(format!("neutrino-receipt-{}", uuid::Uuid::new_v4()));
    let container = root;
    let root = container.join("Modules");
    let call = |action: &str, extra: Value| {
        let mut r = json!({"op":"moduleRepository","root":root,"action":action});
        for (k, v) in extra.as_object().unwrap() {
            r[k] = v.clone();
        }
        let response = neutrino_shell::core_request(r).unwrap();
        assert!(response["error"].is_null(), "{response}");
        response
    };
    call("initialize", json!({}));
    let manifest = json!({"id":"org.test.widget","name":"Widget","version":1,"summary":"Research widget","publisher":"Fixture","source":"https://example.com","capability":"startWidget","dependencies":[],"defaultInstalled":true,"runtime":"declarative"});
    use base64::Engine;
    let payload = base64::engine::general_purpose::STANDARD
        .encode(br#"{"formatVersion":1,"widgetTitle":"Reading","widgetBody":"Keep sources here"}"#);
    call(
        "install",
        json!({"id":"org.test.widget","manifest":manifest,"payload":payload}),
    );
    let scratch = root
        .join("org.test.widget")
        .join(format!(".write-{}", uuid::Uuid::new_v4()));
    std::fs::write(&scratch, "interrupted receipt").unwrap();
    call("initialize", json!({}));
    assert!(!scratch.exists());
    call("begin", json!({"ids":["org.test.widget"]}));
    call("rollback", json!({}));
    std::fs::remove_dir_all(container).unwrap();
}

#[test]
fn removing_chromium_preserves_background_addresses_and_bounded_overflow() {
    let active = json!({"id":"a","engineID":"chromium","url":"https://example.com/a","title":"A","pinned":false,"chromiumPages":[{"url":"https://example.com/a","title":"A"},{"url":"https://example.com/b","title":"B"}]});
    let convert = |tabs| {
        neutrino_shell::core_request(json!({"op":"prepareForChromiumRemoval","value":{"profiles":[{"id":"p","engineID":"chromium"}],"spaces":[{"id":"s","profileID":"p","tabs":tabs,"archivedTabs":[]}],"sessions":[{"id":"w","profileID":"p","spaceID":"s","selectedTabID":"a","tabs":[]}],"bookmarks":[]}})).unwrap()
    };
    let result = convert(json!([active]));
    assert_eq!(result["spaces"][0]["tabs"].as_array().unwrap().len(), 2);
    assert_eq!(
        result["spaces"][0]["tabs"][1]["url"],
        "https://example.com/b"
    );
    assert_eq!(result["sessions"][0]["tabs"].as_array().unwrap().len(), 2);
    assert_eq!(
        result["sessions"][0]["tabs"][1]["id"],
        result["spaces"][0]["tabs"][1]["id"]
    );
    assert_eq!(
        result["sessions"][0]["tabs"][1]["url"],
        "https://example.com/b"
    );
    let mut full = vec![active];
    for i in 1..200 {
        full.push(json!({"id":format!("t{i}"),"title":"Other","pinned":false,"engineID":"webkit"}));
    }
    let result = convert(json!(full));
    assert_eq!(result["spaces"][0]["tabs"].as_array().unwrap().len(), 200);
    assert_eq!(result["bookmarks"][0]["url"], "https://example.com/b");
    assert_eq!(result["bookmarks"][0]["profileID"], "p");
}

#[test]
fn removing_chromium_preserves_large_overflow_once_in_original_order() {
    let tabs: Vec<_> = (0..200).map(|t|json!({"id":format!("tab-{t}"),"title":"Source","engineID":"chromium","pinned":false,"chromiumPages":(0..200).map(|p|json!({"id":format!("{t}-{p}"),"url":format!("https://example.com/{t}/{p}"),"title":format!("{t}/{p}"),"active":p==0})).collect::<Vec<_>>() })).collect();
    let existing = json!({"id":"existing","profileID":"p","url":"https://example.com/0/1","title":"0/1","createdAt":1});
    let result=neutrino_shell::core_request(json!({"op":"prepareForChromiumRemoval","value":{"profiles":[{"id":"p","engineID":"chromium"}],"spaces":[{"id":"s","profileID":"p","tabs":tabs,"archivedTabs":[]}],"sessions":[],"bookmarks":[existing]}})).unwrap();
    let bookmarks = result["bookmarks"].as_array().unwrap();
    assert_eq!(bookmarks.len(), 39_800);
    assert_eq!(bookmarks[0], existing);
    assert_eq!(bookmarks[1]["url"], "https://example.com/0/2");
    assert_eq!(
        bookmarks.last().unwrap()["url"],
        "https://example.com/199/199"
    );
}
#[test]
fn module_presentation_is_validated_in_one_projection_and_corruption_is_local() {
    use base64::Engine;
    let directory =
        std::env::temp_dir().join(format!("neutrino-projection-{}", uuid::Uuid::new_v4()));
    let root = directory.join("Modules");
    let call = |action: &str, fields: Value| {
        let mut r = json!({"op":"moduleRepository","root":root,"action":action});
        for (k, v) in fields.as_object().unwrap() {
            r[k] = v.clone();
        }
        let response = neutrino_shell::core_request(r).unwrap();
        assert!(response["error"].is_null(), "{response}");
        response["result"].clone()
    };
    call("initialize", json!({}));
    for id in ["org.test.first", "org.test.second"] {
        let m = json!({"id":id,"name":id,"version":1,"summary":"Widget","publisher":"Fixture","source":"https://example.com","capability":"startWidget","dependencies":[],"defaultInstalled":true,"runtime":"declarative","settings":[{"id":"label","title":"Label","kind":"text","defaultValue":"Sources"}]});
        call(
            "install",
            json!({"manifest":m,"payload":base64::engine::general_purpose::STANDARD.encode(br#"{"formatVersion":1,"widgetTitle":"Research","widgetBody":"Sources"}"#)}),
        );
    }
    std::fs::write(root.join("org.test.first/definition.json"), b"tampered").unwrap();
    let projection = call("presentation", json!({}));
    assert_eq!(
        projection["settings"]["org.test.second"]["label"],
        "Sources"
    );
    assert_eq!(
        projection["definitions"]["org.test.second"]["widgetTitle"],
        "Research"
    );
    assert!(projection["definitions"]["org.test.first"].is_null());
    assert!(projection["errors"]["org.test.first"]
        .as_str()
        .unwrap()
        .contains("receipt"));
    std::fs::remove_dir_all(directory).unwrap();
}
#[test]
fn portable_note_mutations_keep_sources_and_profile_boundaries() {
    let note = json!({"id":"n","profileID":"p","title":"Note","text":"draft","modifiedAt":1,"sourceURL":"https://example.com","sourceTabID":"t","quotedText":"immutable"});
    let update = |profile: &str, field: &str, output: Value| {
        neutrino_shell::core_request(
            json!({"op":"moduleNote","action":"update","id":"n","profileID":profile,"field":field,"output":output,"value":note}),
        )
    };
    assert!(update("other", "text", json!({"value":"changed"})).is_err());
    assert!(update("p", "sourceURL", json!({"value":"changed"})).is_err());
    let result = update("p", "text", json!({"value":"annotation"})).unwrap();
    assert_eq!(result["note"]["quotedText"], "immutable");
    assert_eq!(result["note"]["sourceTabID"], "t");
    assert_eq!(result["note"]["text"], "annotation");
    assert!(neutrino_shell::core_request(json!({"op":"moduleNote","action":"delete","id":"n","profileID":"p","output":{"delete":false},"value":note})).is_err());
}

#[test]
fn extension_pages_have_owned_controls_and_reject_unknown_native_ids() {
    let mut s = shell();
    s.snapshot["session"]["tabs"][0]["url"] = Value::Null;
    s.snapshot["session"]["tabs"][0]["title"] = json!("New tab");
    s.snapshot["chromePageCounts"] = json!({"a":2});
    s.snapshot["chromePages"] = json!({"a":[{"id":10,"selected":true,"url":"about:blank","title":""},{"id":11,"selected":false,"url":"https://example.com/source","title":"Background source"}]});
    let r = s.dispatch(json!({"op":"sync","snapshot":s.snapshot.clone()}));
    assert!(r["html"].as_str().unwrap().contains("Background source"));
    assert!(r["html"].as_str().unwrap().contains("Extension pages"));
    assert!(commands(&s.dispatch(json!({"op":"chrome-page","id":"a","page":999}))).is_empty());
    assert_eq!(
        commands(&s.dispatch(json!({"op":"chrome-page","id":"a","page":11})))[0],
        json!({"op":"selectChromePage","id":"a","page":11})
    );
    assert_eq!(
        commands(&s.dispatch(json!({"op":"chrome-page-close","id":"a","page":11})))[0],
        json!({"op":"closeChromePage","id":"a","page":11})
    );
}

#[test]
fn source_recovery_distinguishes_equal_url_pages_and_follows_the_original_group() {
    let mut request = json!({"op":"resolveNoteSource","profileID":"p1","spaceID":"s1",
        "spaces":[{"id":"s1","profileID":"p1"},{"id":"s2","profileID":"p1"},{"id":"private","profileID":"p2"}],
        "note":{"profileID":"p1","spaceID":"s1","sourceTabID":"original","sourceURL":"https://example.com/a","sourcePageToken":"process-one:42"},
        "candidates":[{"id":"unrelated","profileID":"p1","spaceID":"s1","url":"https://example.com/a"},
            {"id":"original","profileID":"p2","spaceID":"private","url":"https://example.com/a"},
            {"id":"original","profileID":"p1","spaceID":"s2","url":"https://example.com/b","pages":[
                {"id":43,"url":"https://example.com/a","token":"process-one:43"},
                {"id":42,"url":"https://example.com/a","token":"process-one:42"}]}]});
    let result = neutrino_shell::core_request(request.clone()).unwrap();
    assert_eq!(
        result,
        json!({"spaceID":"s2","tabID":"original","pageID":42})
    );
    // A new process may reuse 42 for a different URL. Old tokens must not
    // override URL verification; the matching restored URL remains usable.
    request["candidates"][2]["pages"] = json!([
        {"id":42,"url":"https://example.com/b","token":"process-two:42"},
        {"id":99,"url":"https://example.com/a","token":"process-two:99"}]);
    assert_eq!(
        neutrino_shell::core_request(request.clone()).unwrap()["pageID"],
        99
    );
    request["candidates"][2]["pages"] = json!([]);
    request["candidates"][2]["restorableURLs"] = json!(["https://example.com/b", "https://example.com/a"]);
    assert_eq!(neutrino_shell::core_request(request.clone()).unwrap(),
        json!({"spaceID":"s2","tabID":"original","restoreURL":"https://example.com/a"}));
    request["note"]["profileID"] = json!("p2");
    assert!(neutrino_shell::core_request(request).is_err());
}

#[test]
fn source_recovery_falls_back_to_an_existing_safe_destination_or_reopens() {
    let mut request = json!({"op":"resolveNoteSource","profileID":"p1","spaceID":"current",
        "spaces":[{"id":"current","profileID":"p1"},{"id":"old","profileID":"p2"}],
        "note":{"profileID":"p1","spaceID":"old","sourceTabID":"gone","sourceURL":"https://example.com/a"},
        "candidates":[{"id":"foreign","profileID":"p2","spaceID":"old","url":"https://example.com/a"},
            {"id":"local","profileID":"p1","spaceID":"current","url":"https://example.com/a"}]});
    assert_eq!(
        neutrino_shell::core_request(request.clone()).unwrap(),
        json!({"spaceID":"current","tabID":"local"})
    );
    request["candidates"] = json!([]);
    assert_eq!(
        neutrino_shell::core_request(request.clone()).unwrap(),
        json!({"spaceID":"current"})
    );
    request["note"]["sourceURL"] = json!("file:///private/source");
    assert!(neutrino_shell::core_request(request).is_err());
}
