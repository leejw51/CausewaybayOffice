mod common;
use cbo_core::*;
use common::*;
use serde_json::{json, Value};
use std::time::{Duration, Instant};

fn job(id: i32, req: Value) -> Value {
    let request = cs(&req.to_string());
    assert_eq!(
        unsafe { cbo_files_start(id, request.as_ptr()) },
        0,
        "{}",
        last_error()
    );
    let start = Instant::now();
    loop {
        let status: Value = serde_json::from_str(&from_c(cbo_files_status(id))).unwrap();
        if status["state"] != "running" {
            return status;
        }
        assert!(start.elapsed() < Duration::from_secs(25), "{status}");
        std::thread::sleep(Duration::from_millis(20));
    }
}
#[test]
fn sftp_roundtrip_and_shell_cwd_without_test_hook() {
    let _serial = serial();
    if !ssh_enabled() {
        eprintln!("skipped: localhost SSH unavailable");
        return;
    }
    cbo_init();
    let _sweep = Sweep;
    let id = connect_local(100, 24);
    let root = isolate_home().join("files space ' percent%25 한글");
    std::fs::create_dir_all(&root).unwrap();
    let source = root.join("source ' %25 한글.bin");
    let remote = root.join("uploaded ' %25 한글.bin");
    let downloaded = root.join("downloaded.bin");
    let bytes: Vec<u8> = (0..300_000).map(|i| (i % 251) as u8).collect();
    std::fs::write(&source, &bytes).unwrap();
    let quote = |s: &str| format!("'{}'", s.replace('\'', "'\\''"));
    // Custom prompt does not contain the working directory. No manually
    // installed OSC hook: this was the hole in the old restart test.
    write(
        id,
        &format!("PS1='work> '; cd {}\n", quote(root.to_str().unwrap())),
    );
    let start = Instant::now();
    while from_c(cbo_term_cwd(id)) != root.to_str().unwrap() {
        assert!(
            start.elapsed() < Duration::from_secs(5),
            "cwd={} screen={:?}",
            from_c(cbo_term_cwd(id)),
            screen(id, 100, 24).0
        );
        std::thread::sleep(Duration::from_millis(30));
    }
    cbo_term_take_bell(id);
    write(id, "ls; printf '\\nCBO_LS_QUIET\\n'\n");
    assert!(wait_row(id, 100, 24, Duration::from_secs(5), |s| s == "CBO_LS_QUIET").is_some());
    std::thread::sleep(Duration::from_millis(150));
    assert_eq!(
        cbo_term_take_bell(id),
        0,
        "ls and the shell's prompt reports must not ring"
    );
    let local = job(id, json!({"op":"local", "local":root}));
    assert_eq!(local["state"], "done", "{local}");
    let upload = job(id, json!({"op":"upload", "local":source, "remote":remote}));
    assert_eq!(upload["state"], "done", "{upload}");
    assert_eq!(upload["done"], bytes.len(), "{upload}");
    // Folder detection is independent of the transfer job and follows links.
    for (path, is_dir) in [(&root, true), (&source, false)] {
        assert_eq!(
            unsafe { cbo_files_probe(id, cs(path.to_str().unwrap()).as_ptr()) },
            0
        );
        let begin = Instant::now();
        loop {
            let st: Value = serde_json::from_str(&from_c(cbo_files_probe_status(id))).unwrap();
            if st["state"] != "running" {
                assert_eq!(st["state"], "done", "{st}");
                assert_eq!(st["result"]["dir"], is_dir, "{st}");
                break;
            }
            assert!(begin.elapsed() < Duration::from_secs(20));
            std::thread::sleep(Duration::from_millis(20));
        }
        let transfer: Value = serde_json::from_str(&from_c(cbo_files_status(id))).unwrap();
        assert_eq!(
            transfer["op"], "upload",
            "folder lookup must not consume transfer status"
        );
    }

    let list = job(id, json!({"op":"list", "remote":root}));
    assert_eq!(list["state"], "done", "{list}");
    assert!(list["result"]["entries"]
        .as_array()
        .unwrap()
        .iter()
        .any(|v| v["name"] == remote.file_name().unwrap().to_str().unwrap()));
    let download = job(
        id,
        json!({"op":"download", "local":downloaded, "remote":remote}),
    );
    assert_eq!(download["state"], "done", "{download}");
    assert_eq!(std::fs::read(&downloaded).unwrap(), bytes);
    for op in ["upload", "download"] {
        let status = job(id, json!({"op":op,"local":source,"remote":remote}));
        assert_eq!(
            status["state"], "error",
            "existing files must be kept: {status}"
        );
    }
    assert_eq!(std::fs::read(&source).unwrap(), bytes);
    // HOT NOTE path: an upload with overwrite replaces the remote file in
    // place through a temp sibling; the folder ends up without leftovers.
    let edited = root.join("edited.txt");
    std::fs::write(&edited, b"edited by hot note\n").unwrap();
    let hot = job(
        id,
        json!({"op":"upload", "local":edited, "remote":remote, "overwrite":true}),
    );
    assert_eq!(hot["state"], "done", "{hot}");
    let check_dl = root.join("after-overwrite.txt");
    let dl = job(
        id,
        json!({"op":"download", "local":check_dl, "remote":remote}),
    );
    assert_eq!(dl["state"], "done", "{dl}");
    assert_eq!(std::fs::read(&check_dl).unwrap(), b"edited by hot note\n");
    let list = job(id, json!({"op":"list", "remote":root}));
    assert!(
        !list["result"]["entries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| {
                let n = v["name"].as_str().unwrap_or("");
                n.ends_with(".cbo-hot") || n.ends_with(".cbo-bak")
            }),
        "no temp or backup file left behind: {list}"
    );
    // overwrite on a missing target simply creates it
    let fresh = root.join("fresh.txt");
    let made = job(
        id,
        json!({"op":"upload", "local":edited, "remote":fresh, "overwrite":true}),
    );
    assert_eq!(made["state"], "done", "{made}");
    // overwrite never turns a folder into a file
    let bad = job(
        id,
        json!({"op":"upload", "local":edited, "remote":root, "overwrite":true}),
    );
    assert_eq!(bad["state"], "error", "{bad}");
    let cancelled_remote = root.join("cancelled.bin");
    let req = cs(&json!({"op":"upload", "local":source, "remote":cancelled_remote}).to_string());
    assert_eq!(unsafe { cbo_files_start(id, req.as_ptr()) }, 0);
    assert_eq!(
        unsafe { cbo_files_start(id, req.as_ptr()) },
        -1,
        "overlapping transfers must be rejected"
    );
    cbo_files_cancel(id);
    let deadline = Instant::now();
    loop {
        let st: Value = serde_json::from_str(&from_c(cbo_files_status(id))).unwrap();
        if st["state"] != "running" {
            assert_eq!(st["state"], "cancelled", "{st}");
            break;
        }
        assert!(deadline.elapsed() < Duration::from_secs(20));
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(
        !cancelled_remote.exists(),
        "cancel must not leave a partial file"
    );
    let missing = job(id, json!({"op":"list","remote":root.join("missing")}));
    assert_eq!(missing["state"], "error");
    write(id, "printf '\\nterminal-still-works\\n'\n");
    assert!(wait_row(id, 100, 24, Duration::from_secs(3), |s| s
        == "terminal-still-works")
    .is_some());
}
