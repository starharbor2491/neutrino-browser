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
    for _ in 0..5 {
        s.dispatch(json!({"op":"setup-next"}));
    }
    assert_eq!(s.step, 6);
    assert_eq!(commands(&s.dispatch(json!({"op":"setup-finish"}))).len(), 1);
    assert!(commands(&s.dispatch(json!({"op":"setup-finish"}))).is_empty());
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
fn undo_toast_is_attached_only_to_the_tab_move() {
    let mut s = shell();
    s.dispatch(json!({"op":"move-tab","id":"a","group":"pinned"}));
    s.dispatch(json!({"op":"screen","value":"editor"}));
    let r = s.dispatch(json!({"op":"editor-save"}));
    assert!(r["html"].as_str().unwrap().contains("Appearance saved."));
    assert!(!r["html"]
        .as_str()
        .unwrap()
        .contains("Appearance saved.</span><button"));
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
    s.dispatch(json!({"op":"reveal-workspace"}));
    assert_eq!(s.screen, "browse");
    assert!(!s.sidebar_hidden);
}
