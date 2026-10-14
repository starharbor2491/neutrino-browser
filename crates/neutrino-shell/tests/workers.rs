// SPDX-License-Identifier: MPL-2.0
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};

fn read_page(input: &[u8]) -> Value {
    let mut child = Command::new(env!("CARGO_BIN_EXE_neutrino-reader-worker"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let _ = child.stdin.take().unwrap().write_all(input);
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    serde_json::from_slice(&output.stdout).unwrap()
}
#[test]
fn reader_process_preserves_unicode_and_rejects_active_or_malformed_markup() {
    let request = json!({"html":"<html><body><nav>Hidden navigation</nav><article><p>Source quotation — 星</p></article><script>throw 1</script></body></html>"});
    let response = read_page(&serde_json::to_vec(&request).unwrap());
    assert_eq!(response["text"], "Source quotation — 星");
    assert!(response.get("error").is_none());
    for html in [
        "<!DOCTYPE a [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><a>&secret;</a>",
        "<html><p>Unclosed",
    ] {
        let response = read_page(&serde_json::to_vec(&json!({"html":html})).unwrap());
        assert_eq!(response["text"], "");
        assert!(response["error"].as_str().is_some());
    }
}
#[test]
fn reader_process_rejects_transport_and_snapshot_size_overflow() {
    for input in [
        b"not JSON".to_vec(),
        vec![b'x'; 2 * 1024 * 1024 + 1],
        serde_json::to_vec(&json!({"html":"x".repeat(1024*1024+1)})).unwrap(),
    ] {
        let response = read_page(&input);
        assert_eq!(response["text"], "");
        assert!(response["error"].as_str().unwrap().len() < 500);
    }
}
#[test]
fn resource_processes_publish_frames_and_exit_on_owner_eof() {
    for (path, title) in [
        (
            env!("CARGO_BIN_EXE_neutrino-resource-monitor"),
            "Resource Monitor",
        ),
        (
            env!("CARGO_BIN_EXE_neutrino-memory-monitor"),
            "Memory Breakdown",
        ),
    ] {
        let mut child = Command::new(path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut line = String::new();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut line)
            .unwrap();
        let frame: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(frame["title"], title);
        assert!(!frame["metrics"].as_array().unwrap().is_empty());
        drop(child.stdin.take());
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        loop {
            if let Some(status) = child.try_wait().unwrap() {
                assert!(status.success());
                break;
            }
            if std::time::Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                panic!("Worker survived owner EOF");
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }
}
