//! Persistence, recording, search and patterns against a real sqlite file in
//! a temp CBO_HOME. Mixes the public Rust API (fake sessions fed without
//! ssh) with the C ABI entry points.

mod common;

use std::sync::atomic::Ordering;
use std::time::Duration;

use cbo_core::session::{ConnectParams, Session};
use cbo_core::*;
use common::*;
use serde_json::Value;

fn j(p: *const std::ffi::c_char) -> Value {
    serde_json::from_str(&from_c(p)).unwrap_or(Value::Null)
}

fn fake_session(slot: i32, user: &str, host: &str) -> Session {
    Session::new(
        slot,
        ConnectParams {
            host: host.into(),
            port: 22,
            user: user.into(),
            password: None,
            keypath: None,
        },
        format!("fake-{}", slot),
        80,
        24,
    )
}

/// Build a fake recorded session with a few commands and some output.
fn record_fake(slot: i32, cmds: &[&str], output: &[u8]) -> i64 {
    let sess = fake_session(slot, "tester", "fake.host");
    record::session_started(&sess);
    let db_id = record::db_session_id(&sess).expect("recording is on");
    for c in cmds {
        sess.write(format!("{}\r", c).as_bytes());
        record::on_output(&sess, format!("{}\r\n", c).as_bytes());
    }
    record::on_output(&sess, output);
    sess.set_state(ST_CLOSED); // ends the recording
    record::flush_now().expect("flush");
    db_id
}

#[test]
fn data_dir_is_cbo_home_and_kv_roundtrips_cjk() {
    let _g = serial();
    cbo_init();
    cbo_record_enable(1);
    let home = isolate_home();
    assert_eq!(from_c(cbo_data_dir()), home.to_string_lossy());
    assert!(home.join("office.db").exists(), "db file created");
    let k = cs("apikey.demo");
    let v = cs("銅鑼灣 안녕 こんにちは Příliš");
    assert_eq!(unsafe { cbo_kv_set(k.as_ptr(), v.as_ptr()) }, 0);
    assert_eq!(
        from_c(unsafe { cbo_kv_get(k.as_ptr()) }),
        "銅鑼灣 안녕 こんにちは Příliš"
    );
    let v2 = cs("");
    assert_eq!(unsafe { cbo_kv_set(k.as_ptr(), v2.as_ptr()) }, 0);
    assert_eq!(from_c(unsafe { cbo_kv_get(k.as_ptr()) }), "");
    let missing = cs("nope.key");
    assert_eq!(from_c(unsafe { cbo_kv_get(missing.as_ptr()) }), "");
    assert_eq!(unsafe { cbo_kv_set(std::ptr::null(), v.as_ptr()) }, -1);
    assert!(last_error().contains("key"));
}

#[test]
fn host_upsert_dedupes_and_lists_by_last_used() {
    let _g = serial();
    cbo_init();
    cbo_record_enable(1);
    let a = cs(
        r#"{"name":"dev","host":"dev.hk","port":22,"user":"lee","tags":"work","last_used_ms":100}"#,
    );
    let id_a = unsafe { cbo_host_upsert(a.as_ptr()) };
    assert!(id_a > 0, "{}", last_error());
    let b = cs(r#"{"name":"prod","host":"prod.hk","port":2222,"user":"root","last_used_ms":500}"#);
    let id_b = unsafe { cbo_host_upsert(b.as_ptr()) };
    assert!(id_b > 0 && id_b != id_a);
    // Same user@host:port without id -> same row, name kept when blank.
    let dup = cs(r#"{"host":"dev.hk","port":22,"user":"lee","tags":"work,hk","last_used_ms":900}"#);
    assert_eq!(unsafe { cbo_host_upsert(dup.as_ptr()) }, id_a);
    let got = j(cbo_host_get(id_a));
    assert_eq!(got["name"], "dev");
    assert_eq!(got["tags"], "work,hk");
    assert_eq!(got["last_used_ms"], 900);
    // Update by id can change the address.
    let byid = cs(&format!(
        r#"{{"id":{},"name":"dev2","host":"dev2.hk","port":22,"user":"lee"}}"#,
        id_a
    ));
    assert_eq!(unsafe { cbo_host_upsert(byid.as_ptr()) }, id_a);
    assert_eq!(j(cbo_host_get(id_a))["host"], "dev2.hk");

    let list = j(cbo_host_list());
    let ids: Vec<i64> = list
        .as_array()
        .expect("array")
        .iter()
        .map(|h| h["id"].as_i64().unwrap_or(0))
        .collect();
    assert_eq!(ids, vec![id_a as i64, id_b as i64], "last_used desc");

    let bad = cs(r#"{"host":"x"}"#);
    assert_eq!(unsafe { cbo_host_upsert(bad.as_ptr()) }, -1);
    assert!(last_error().contains("user"));
    let notjson = cs("nope");
    assert_eq!(unsafe { cbo_host_upsert(notjson.as_ptr()) }, -1);

    assert_eq!(cbo_host_delete(id_b), 0);
    assert_eq!(cbo_host_delete(id_b), -1);
    assert_eq!(from_c(cbo_host_get(id_b)), "");
    assert_eq!(j(cbo_host_list()).as_array().map(|a| a.len()), Some(1));
    assert_eq!(cbo_host_delete(id_a), 0);
}

#[test]
fn recording_commands_transcript_and_bm25() {
    let _g = serial();
    cbo_init();
    cbo_record_enable(1);
    assert_eq!(cbo_record_enabled(), 1, "recording defaults to on");
    let out = "\x1b[32mREC_LINE one\x1b[0m\r\nline two 你好\r\n".as_bytes();
    let db_id = record_fake(
        7,
        &[
            "git status",
            "echo 세션 이름",
            "ls -la",
            "wrong\x7f\x7f\x7f\x7f\x7fecho fixed",
        ],
        out,
    );
    assert!(db_id > 0);

    // Commands table + FTS.
    let recent = j(cbo_recent_commands(0, 10));
    let cmds: Vec<String> = recent
        .as_array()
        .expect("array")
        .iter()
        .map(|c| c["cmd"].as_str().unwrap_or("").to_string())
        .collect();
    assert_eq!(cmds[0], "echo fixed", "newest first, backspaces applied");
    assert!(cmds.contains(&"git status".to_string()));
    assert!(cmds.contains(&"echo 세션 이름".to_string()));
    assert_eq!(recent[0]["session_id"], db_id);

    let q = cs("git status");
    let k = cs("command");
    let hits = j(unsafe { cbo_search_bm25(q.as_ptr(), k.as_ptr(), 10) });
    assert_eq!(hits[0]["kind"], "command");
    assert_eq!(hits[0]["title"], "git status");
    assert_eq!(hits[0]["sources"], serde_json::json!(["bm25"]));
    assert!(hits[0]["score"].as_f64().unwrap_or(0.0) > 0.0);

    let q = cs("세션 이름");
    let hits = j(unsafe { cbo_search_bm25(q.as_ptr(), std::ptr::null(), 10) });
    assert!(
        hits.as_array()
            .map(|a| a
                .iter()
                .any(|h| h["kind"] == "command" && h["title"] == "echo 세션 이름"))
            .unwrap_or(false),
        "korean command found: {}",
        hits
    );

    // Transcript FTS (output lines) and the ANSI-stripped tail.
    let q = cs("REC_LINE");
    let k = cs("transcript");
    let hits = j(unsafe { cbo_search_bm25(q.as_ptr(), k.as_ptr(), 10) });
    assert_eq!(hits[0]["kind"], "transcript", "{}", hits);
    assert_eq!(hits[0]["session_id"], db_id);
    assert!(hits[0]["snippet"]
        .as_str()
        .unwrap_or("")
        .contains("REC_LINE"));

    let t = from_c(cbo_session_transcript(db_id as i32, 4096));
    assert!(t.contains("REC_LINE one\nline two 你好"), "{:?}", t);
    assert!(!t.contains("\x1b"), "escapes stripped");
    let tail = from_c(cbo_session_transcript(db_id as i32, 6));
    assert_eq!(tail, "好\n", "tail never starts inside a multi-byte char");
    let tail = from_c(cbo_session_transcript(db_id as i32, 12));
    assert!(tail.ends_with("two 你好\n"), "{:?}", tail);

    // Session row was closed.
    let sessions = db::with(|c| {
        c.query_row(
            "SELECT end_state, ended_ms > 0, name FROM sessions WHERE id = ?1",
            [db_id],
            |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, bool>(1)?,
                    r.get::<_, String>(2)?,
                ))
            },
        )
        .map_err(db::sql_err)
    })
    .expect("row");
    assert_eq!(sessions, (ST_CLOSED as i64, true, "fake-7".to_string()));
    assert!(
        cbo_embed_pending() >= 4,
        "commands + transcript wait for embeddings"
    );
}

#[test]
fn record_disable_stops_recording() {
    let _g = serial();
    cbo_init();
    cbo_record_enable(1);
    let active = fake_session(29, "u", "h");
    record::session_started(&active);
    active.write(b"public_before_pause\r");
    cbo_record_enable(0);
    active.write(b"private_after_pause\r");
    record::on_output(&active, b"private_output_after_pause\n");
    assert_eq!(
        record::event(
            "ai",
            "terminal",
            "reply",
            r#"{"content":"private_ai_after_pause"}"#
        )
        .unwrap(),
        0
    );
    assert_eq!(record::typing(&active), "");
    assert_eq!(cbo_record_enabled(), 0);
    let k = cs("record");
    assert_eq!(from_c(unsafe { cbo_kv_get(k.as_ptr()) }), "0");
    let sess = fake_session(9, "u", "h");
    record::session_started(&sess);
    assert!(record::db_session_id(&sess).is_none());
    sess.write(b"secret command\r");
    record::flush_now().expect("flush");
    for query in [
        "private_after_pause",
        "secret",
        "private_output_after_pause",
        "private_ai_after_pause",
    ] {
        let q = cs(query);
        let hits = j(unsafe { cbo_search_bm25(q.as_ptr(), std::ptr::null(), 10) });
        assert_eq!(
            hits.as_array().map(|a| a.len()),
            Some(0),
            "{} leaked",
            query
        );
    }
    cbo_record_enable(1);
    assert_eq!(cbo_record_enabled(), 1);
}

#[test]
fn events_ai_messages_and_suggest() {
    let _g = serial();
    cbo_init();
    cbo_record_enable(1);
    patterns::reset_chain();
    let ev = |kind: &str, scene: &str, action: &str, data: &str| -> i64 {
        let (k, s, a, d) = (cs(kind), cs(scene), cs(action), cs(data));
        unsafe { cbo_record_event(k.as_ptr(), s.as_ptr(), a.as_ptr(), d.as_ptr()) }
    };
    for _ in 0..3 {
        assert!(ev("nav", "lobby", "connect", "{}") > 0);
        assert!(ev("nav", "terminal", "back", "{}") > 0);
        patterns::reset_chain();
    }
    assert!(ev("ui", "lobby", "search", r#"{"query":"tram"}"#) > 0);
    patterns::reset_chain();
    assert!(
        ev(
            "note",
            "lobby",
            "",
            r#"{"text":"remember the causeway host"}"#
        ) > 0
    );
    let ai = ev(
        "ai",
        "terminal",
        "ask",
        r#"{"provider":"xai","model":"grok-4.6","role":"assistant","content":"Use rsync -avz for the transfer","session_id":0}"#,
    );
    assert!(ai > 0);
    let bad = cs("");
    assert_eq!(
        unsafe { cbo_record_event(bad.as_ptr(), bad.as_ptr(), bad.as_ptr(), bad.as_ptr()) },
        -1
    );

    let s = cs("lobby");
    let e = cs("");
    let sug = j(unsafe { cbo_suggest(s.as_ptr(), e.as_ptr(), 5) });
    assert_eq!(sug[0]["action"], "connect");
    assert_eq!(sug[0]["count"], 3);
    assert_eq!(sug[1]["action"], "search");
    assert!(sug[0]["prob"].as_f64().unwrap_or(0.0) > sug[1]["prob"].as_f64().unwrap_or(1.0));

    let q = cs("rsync");
    let hits = j(unsafe { cbo_search_bm25(q.as_ptr(), std::ptr::null(), 10) });
    assert!(
        hits.as_array()
            .map(|a| a.iter().any(|h| h["kind"] == "ai" && h["id"] == 1))
            .unwrap_or(false),
        "{}",
        hits
    );
    let q = cs("causeway");
    let k = cs("event");
    let hits = j(unsafe { cbo_search_bm25(q.as_ptr(), k.as_ptr(), 10) });
    assert_eq!(hits[0]["kind"], "event", "{}", hits);
    assert!(hits[0]["title"]
        .as_str()
        .unwrap_or("")
        .starts_with("note/lobby"));

    let stats = j(cbo_stats());
    assert!(stats["counts"]["events"].as_i64().unwrap_or(0) >= 9);
    assert_eq!(stats["counts"]["ai_messages"], 1);
    assert!(stats["db_bytes"].as_i64().unwrap_or(0) > 0);
    assert_eq!(stats["record_enabled"], true);
}

#[test]
fn context_bundle_shape() {
    let _g = serial();
    cbo_init();
    cbo_record_enable(1);
    let db_id = record_fake(
        11,
        &["uptime", "df -h"],
        b"Filesystem  Size\r\n/dev/disk1  1T\r\n",
    );
    let s = cs("terminal");
    let ctx = j(unsafe { cbo_context(s.as_ptr(), db_id as i32, 200) });
    assert_eq!(ctx["scene"], "terminal");
    assert!(ctx["session"].is_null(), "no live session in that slot");
    assert!(ctx["live_sessions"].is_array());
    let recent = ctx["recent_commands"].as_array().expect("recent");
    assert!(recent.iter().any(|c| c["cmd"] == "df -h"));
    let tail = ctx["transcript_tail"].as_str().unwrap_or("");
    assert!(tail.contains("/dev/disk1"), "{:?}", tail);
    assert!(tail.len() <= 200);
    assert!(ctx["frequent_hosts"].is_array());
    assert!(ctx["suggestions"].is_array());
    assert!(ctx["stats"]["counts"]["sessions"].as_i64().unwrap_or(0) >= 1);

    // A live session (CONNECTING to a black hole) shows up with its geometry.
    let id = open(BLACKHOLE, 22, "ctx", None, None, 100, 30);
    assert!(id >= 0);
    let ctx = j(unsafe { cbo_context(s.as_ptr(), id, 200) });
    assert_eq!(ctx["session"]["cols"], 100);
    assert_eq!(ctx["session"]["user"], "ctx");
    assert!(ctx["live_sessions"]
        .as_array()
        .map(|a| !a.is_empty())
        .unwrap_or(false));
    cbo_session_close(id);
    let t = std::time::Instant::now();
    while !matches!(cbo_session_state(id), ST_CLOSED | ST_ERROR)
        && t.elapsed() < Duration::from_secs(5)
    {
        std::thread::sleep(Duration::from_millis(10));
    }
    cbo_session_free(id);
}

#[test]
fn session_set_host_links_and_touches() {
    let _g = serial();
    cbo_init();
    cbo_record_enable(1);
    let h = cs(r#"{"name":"bh","host":"10.255.255.1","port":22,"user":"linkme"}"#);
    let hid = unsafe { cbo_host_upsert(h.as_ptr()) };
    assert!(hid > 0);
    let before = j(cbo_host_get(hid))["use_count"].as_i64().unwrap_or(-1);
    // Auto-link: a session to a known user@host:port picks the host row up.
    let id = open(BLACKHOLE, 22, "linkme", None, None, 80, 24);
    assert!(id >= 0);
    let s = session::get(id).expect("live");
    assert_eq!(s.host_id.load(Ordering::Relaxed), hid as i64);
    assert_eq!(j(cbo_host_get(hid))["use_count"], before + 1);
    // Explicit link to another host.
    let h2 = cs(r#"{"name":"other","host":"other.hk","port":22,"user":"x"}"#);
    let hid2 = unsafe { cbo_host_upsert(h2.as_ptr()) };
    assert_eq!(cbo_session_set_host(id, hid2), 0);
    assert_eq!(s.host_id.load(Ordering::Relaxed), hid2 as i64);
    assert_eq!(cbo_session_set_host(id, 999_999), -1);
    assert!(last_error().contains("no host"));
    assert_eq!(s.host_id.load(Ordering::Relaxed), hid2 as i64);
    assert_eq!(cbo_session_set_host(999, hid2), -1);
    cbo_session_close(id);
    let t = std::time::Instant::now();
    while !matches!(cbo_session_state(id), ST_CLOSED | ST_ERROR)
        && t.elapsed() < Duration::from_secs(5)
    {
        std::thread::sleep(Duration::from_millis(10));
    }
    cbo_session_free(id);
    record::flush_now().expect("flush");
    let linked: i64 = db::with(|c| {
        c.query_row(
            "SELECT host_id FROM sessions WHERE slot = ?1 ORDER BY id DESC LIMIT 1",
            [id],
            |r| r.get(0),
        )
        .map_err(db::sql_err)
    })
    .expect("row");
    assert_eq!(linked, hid2 as i64);
    cbo_host_delete(hid);
    cbo_host_delete(hid2);
}

#[test]
fn pruning_keeps_io_under_max_mb() {
    let _g = serial();
    cbo_init();
    cbo_record_enable(1);
    let k = cs("record.max_mb");
    let v = cs("1");
    assert_eq!(unsafe { cbo_kv_set(k.as_ptr(), v.as_ptr()) }, 0);
    let sess = fake_session(13, "big", "h");
    record::session_started(&sess);
    let chunk = vec![b'x'; 64 * 1024];
    for _ in 0..40 {
        record::on_output(&sess, &chunk); // 2.5 MB total
    }
    sess.set_state(ST_CLOSED);
    record::flush_now().expect("flush");
    let total: i64 = db::with(|c| {
        c.query_row(
            "SELECT COALESCE(SUM(LENGTH(bytes)),0) FROM io_chunks",
            [],
            |r| r.get(0),
        )
        .map_err(db::sql_err)
    })
    .expect("sum");
    assert!(total <= 1024 * 1024, "io_chunks {} bytes > 1 MB cap", total);
    assert!(total > 0, "pruning keeps the newest chunks");
    let v = cs("512");
    assert_eq!(unsafe { cbo_kv_set(k.as_ptr(), v.as_ptr()) }, 0);
}

#[test]
fn semantic_and_hybrid_search_with_openai() {
    let _g = serial();
    cbo_init();
    cbo_record_enable(1);
    if env_key("openai").is_none() {
        println!("skipped remote part: no OPENAI_API_KEY; checking the local model");
        assert_eq!(cbo_embed_available(), 0, "no OpenAI indexing");
        embed::set_paused(true);
        record_fake(
            22,
            &["ls -la", "git push origin main", "docker compose up -d"],
            b"",
        );
        db::with(embed::run_local_all).expect("local vectors");
        assert_eq!(cbo_embed_pending(), 0, "local model leaves nothing pending");
        let q = cs("pushing to origin");
        let k = cs("command");
        let hits = j(unsafe { cbo_search_semantic(q.as_ptr(), k.as_ptr(), 3) });
        assert_eq!(hits[0]["title"], "git push origin main", "{}", hits);
        assert_eq!(hits[0]["sources"], serde_json::json!(["semantic"]));
        let q = cs("origin");
        let hits = j(unsafe { cbo_search(q.as_ptr(), k.as_ptr(), 3) });
        assert_eq!(hits[0]["title"], "git push origin main", "{}", hits);
        assert_eq!(
            hits[0]["sources"].as_array().map(|s| s.len()),
            Some(2),
            "BM25 and the vector pass fuse: {}",
            hits
        );
        embed::set_paused(false);
        return;
    }
    db::with(|c| db::kv_set(c, "embed.enabled", "1")).expect("opt in");
    embed::set_paused(true);
    assert_eq!(cbo_embed_available(), 1);
    record_fake(
        21,
        &["ls -la", "git push origin main", "docker compose up -d"],
        b"",
    );
    let t = std::time::Instant::now();
    while cbo_embed_pending() > 0 && t.elapsed() < Duration::from_secs(90) {
        embed::run_once().expect("embed batch");
    }
    assert_eq!(cbo_embed_pending(), 0);

    let q = cs("list files");
    let k = cs("command");
    let hits = j(unsafe { cbo_search_semantic(q.as_ptr(), k.as_ptr(), 3) });
    assert_eq!(hits[0]["title"], "ls -la", "{}", hits);
    assert_eq!(hits[0]["sources"], serde_json::json!(["semantic"]));
    assert!(hits[0]["score"].as_f64().unwrap_or(0.0) > 0.2);

    let hits = j(unsafe { cbo_search(q.as_ptr(), k.as_ptr(), 3) });
    assert_eq!(hits[0]["title"], "ls -la", "{}", hits);
    assert!(hits[0]["sources"]
        .as_array()
        .map(|s| s.iter().any(|x| x == "semantic"))
        .unwrap_or(false));

    // Hybrid: a lexical hit and a semantic hit fuse; both sources appear.
    let q = cs("ls");
    let hits = j(unsafe { cbo_search(q.as_ptr(), k.as_ptr(), 5) });
    let top = &hits[0];
    assert_eq!(top["title"], "ls -la");
    assert_eq!(
        top["sources"].as_array().map(|s| s.len()),
        Some(2),
        "{}",
        hits
    );
    db::with(|c| db::kv_set(c, "embed.enabled", "0")).expect("opt out");
    embed::set_paused(false);
}

#[test]
fn typing_state_and_next_command_prediction() {
    let _g = serial();
    cbo_init();
    cbo_record_enable(1);
    let sess = fake_session(31, "typer", "type.host");
    record::session_started(&sess);
    // Typing state through the public API (what cbo_session_typing returns).
    sess.write(b"gi");
    sess.write(b"t");
    sess.write(&[0x7f]);
    sess.write(b"t st");
    assert_eq!(record::typing(&sess), "git st");
    sess.write(b"\xed\x95");
    sess.write(b"\x9c"); // 한 split across writes
    assert_eq!(record::typing(&sess), "git st한");
    sess.write(&[0x7f]);
    assert_eq!(record::typing(&sess), "git st");
    sess.write(b"atus\r");
    assert_eq!(record::typing(&sess), "", "reset on Enter");
    sess.write(b"junk");
    sess.write(&[0x03]);
    assert_eq!(record::typing(&sess), "", "reset on Ctrl-C");
    // A command chain: cd x -> ls, twice.
    for _ in 0..2 {
        sess.write(b"cd x\r");
        sess.write(b"ls\r");
    }
    sess.write(b"cd x\r");
    record::flush_now().expect("flush");
    let recent = j(cbo_recent_commands(0, 3));
    assert_eq!(recent[0]["cmd"], "cd x");
    assert_eq!(recent[2]["cmd"], "cd x");

    let p = j(cbo_predict_next(0, 5));
    assert_eq!(p[0]["cmd"], "ls", "{}", p);
    assert_eq!(p[0]["source"], "pattern");
    assert_eq!(p[0]["count"], 2);
    let pre = cs("git s");
    let c = j(unsafe { cbo_complete(0, pre.as_ptr(), 5) });
    assert_eq!(c[0]["cmd"], "git status", "{}", c);
    assert!(c[0]["last_ms"].as_i64().unwrap_or(0) > 0);
    let empty = cs("");
    let c = j(unsafe { cbo_complete(0, empty.as_ptr(), 2) });
    assert_eq!(c.as_array().map(|a| a.len()), Some(2));
    assert_eq!(c[0]["cmd"], "cd x", "most frequent first: {}", c);
    assert_eq!(from_c(cbo_session_typing(-1)), "");
    sess.set_state(ST_CLOSED);
}

/// Notes through the C ABI: stored while recording is off, listed newest
/// first, found by BM25 and by the offline vector pass, gone after delete.
#[test]
fn notes_through_the_c_abi() {
    let _g = serial();
    cbo_init();
    cbo_record_enable(0);
    embed::set_paused(true);
    let before = j(cbo_note_list(0)).as_array().map(|a| a.len()).unwrap_or(0);

    let blank = cs("  \n\t");
    assert_eq!(unsafe { cbo_note_add(blank.as_ptr(), 0) }, -1);
    assert!(last_error().contains("empty"), "{}", last_error());

    let a = cs("ABI note: rotate the nginx certificate on the causeway box\nsudo certbot renew");
    let b = cs("ABI note: 銅鑼灣 office wifi is on the whiteboard");
    let ida = unsafe { cbo_note_add(a.as_ptr(), 7) };
    let idb = unsafe { cbo_note_add(b.as_ptr(), 0) };
    assert!(ida > 0 && idb > ida, "ids grow: {} {}", ida, idb);
    assert_eq!(last_error(), "");

    let list = j(cbo_note_list(0));
    let list = list.as_array().expect("array");
    assert_eq!(list.len(), before + 2);
    assert_eq!(list[0]["id"], idb, "newest first");
    assert_eq!(list[1]["session_id"], 7);
    assert!(list[1]["text"].as_str().unwrap_or("").contains("certbot"));
    assert!(list[0]["ts_ms"].as_i64().unwrap_or(0) > 0);
    assert_eq!(j(cbo_note_list(1)).as_array().map(|a| a.len()), Some(1));

    let q = cs("銅鑼灣");
    let k = cs("note");
    let hits = j(unsafe { cbo_search_bm25(q.as_ptr(), k.as_ptr(), 5) });
    assert_eq!(hits[0]["id"], idb, "{}", hits);
    assert_eq!(hits[0]["kind"], "note");
    assert_eq!(
        hits[0]["title"],
        "ABI note: 銅鑼灣 office wifi is on the whiteboard"
    );
    // Offline vector pass: an inflection BM25 cannot prefix-match.
    if cbo_embed_available() == 0 {
        let q = cs("renewing certificates");
        let hits = j(unsafe { cbo_search(q.as_ptr(), k.as_ptr(), 5) });
        assert_eq!(hits[0]["id"], ida, "{}", hits);
        assert!(hits[0]["sources"]
            .as_array()
            .map(|s| s.iter().any(|x| x == "semantic"))
            .unwrap_or(false));
        assert_eq!(
            hits.as_array().map(|a| a.len()),
            Some(1),
            "the unrelated note is below the local score floor: {}",
            hits
        );
    }
    // Notes are part of "" (all kinds) too.
    let q = cs("whiteboard");
    let all = j(unsafe { cbo_search_bm25(q.as_ptr(), std::ptr::null(), 5) });
    assert!(all
        .as_array()
        .map(|a| a.iter().any(|h| h["kind"] == "note"))
        .unwrap_or(false));

    assert_eq!(cbo_note_delete(ida), 0);
    assert_eq!(cbo_note_delete(ida), -1);
    assert!(last_error().contains("no such note"));
    let q = cs("certbot");
    let gone = j(unsafe { cbo_search(q.as_ptr(), k.as_ptr(), 5) });
    assert_eq!(gone.as_array().map(|a| a.len()), Some(0), "{}", gone);
    assert_eq!(cbo_note_delete(idb), 0);
    assert_eq!(
        j(cbo_note_list(0)).as_array().map(|a| a.len()),
        Some(before)
    );
    embed::set_paused(false);
}
