//! Real SSH against the local sshd (CBO_IT=1 or 127.0.0.1:22 answering;
//! otherwise every test prints "skipped" and passes). All tests share the
//! global registry, so they serialise on `common::SERIAL`.

mod common;

use std::time::{Duration, Instant};

use cbo_core::*;
use common::*;

macro_rules! gate {
    () => {
        if !ssh_enabled() {
            println!("skipped: no sshd on 127.0.0.1:22 and CBO_IT not set");
            return;
        }
    };
}

/// Run a shell command and return the row that starts with `marker`.
fn run_marked(id: i32, cols: usize, rows: usize, cmd: &str, marker: &str) -> String {
    write(id, &format!("{}\n", cmd));
    let (r, lines, _) = wait_row(id, cols, rows, Duration::from_secs(5), |l| {
        l.starts_with(marker)
    })
    .unwrap_or_else(|| panic!("no row starting with {:?} after {:?}", marker, cmd));
    lines[r].clone()
}

#[test]
fn connect_echo_and_close() {
    gate!();
    let _g = serial();
    let _sweep = Sweep;
    cbo_init();
    let t0 = Instant::now();
    let id = open_local(80, 24);
    wait_state(id, ST_CONNECTED, Duration::from_secs(10)).expect("CONNECTED within 10 s");
    let connect_ms = t0.elapsed().as_millis();
    assert_eq!(info(id).state, ST_CONNECTED);
    wait_shell_prompt(id);
    let gen0 = cbo_term_generation(id);
    assert!(gen0 > 0, "prompt must have bumped the generation");

    write(id, "echo CBO_OK 你好 안녕\n");
    let (r, lines, cells) = wait_row(id, 80, 24, Duration::from_secs(5), |l| {
        l == "CBO_OK 你好 안녕"
    })
    .expect("output row");
    assert!(cbo_term_generation(id) > gen0);
    let base = r * 80;
    assert_eq!(cells[base + 7].cp, '你' as u32);
    assert_eq!(cells[base + 7].width, 2);
    assert_eq!(cells[base + 8].width, 0);
    assert_eq!(cells[base + 9].cp, '好' as u32);
    assert_eq!(cells[base + 12].cp, '안' as u32);
    assert_eq!(cells[base + 14].cp, '녕' as u32);
    assert!(
        lines.iter().any(|l| l.contains("echo CBO_OK")),
        "command echo visible"
    );
    let i = info(id);
    assert!(i.last_activity_ms >= i.created_ms);
    println!(
        "connected in {} ms, name {}",
        connect_ms,
        from_c(cbo_session_get_name(id))
    );

    write(id, "exit\n");
    wait_state(id, ST_CLOSED, Duration::from_secs(10)).expect("CLOSED after exit");
    cbo_session_free(id);
    assert_eq!(cbo_session_count(), 0);
}

#[test]
fn unicode_matrix_round_trip() {
    gate!();
    let _g = serial();
    let _sweep = Sweep;
    cbo_init();
    let (cols, rows) = (200usize, 30usize);
    let id = connect_local(cols as u16, rows as u16);

    for case in MATRIX {
        // Input path + output path byte-exact: the shell hex-dumps what it got.
        let cmd = format!(
            "printf '%s' '{}' | xxd -p | tr -d '\\n' | sed 's/^/HEX{}=/'; echo",
            case.text, case.label
        );
        let marker = format!("HEX{}=", case.label);
        let line = run_marked(id, cols, rows, &cmd, &marker);
        assert_eq!(
            &line[marker.len()..],
            hex(case.text.as_bytes()),
            "[{}] bytes through ssh differ",
            case.label
        );

        // Echo: code points, per-cell widths, total width, cursor column.
        write(
            id,
            &format!("printf '\\n%s' '{}'; sleep 1; echo\n", case.text),
        );
        let expected = expected_cells(case.text);
        // What the screen shows: base chars only (a combining mark is folded).
        let shown: String = expected
            .iter()
            .filter(|(_, w)| *w != 0)
            .map(|(cp, _)| char::from_u32(*cp).unwrap_or('?'))
            .collect();
        let (r, _lines, cells) = wait_row(id, cols, rows, Duration::from_secs(5), |l| {
            l == shown.trim_end()
        })
        .unwrap_or_else(|| panic!("[{}] echoed row not found", case.label));
        let base = r * cols;
        for (i, (cp, w)) in expected.iter().enumerate() {
            assert_eq!(cells[base + i].cp, *cp, "[{}] cell {} cp", case.label, i);
            assert_eq!(
                cells[base + i].width,
                *w,
                "[{}] cell {} width",
                case.label,
                i
            );
        }
        assert_eq!(
            cells[base + expected.len()].cp,
            0,
            "[{}] blank after",
            case.label
        );
        assert_eq!(
            utf8_width(case.text),
            case.cols as i32,
            "[{}] cbo_utf8_width",
            case.label
        );
        // While `sleep 1` runs the cursor sits right after the text.
        let (x, y, vis) = cursor(id);
        assert_eq!(
            (x, y as usize, vis),
            (case.cols, r, 1),
            "[{}] cursor after echo",
            case.label
        );
        // Wait for the prompt to come back below the echoed row.
        let t = Instant::now();
        while cursor(id).1 as usize <= r && t.elapsed() < Duration::from_secs(5) {
            std::thread::sleep(Duration::from_millis(20));
        }
        std::thread::sleep(Duration::from_millis(150));
    }

    // Czech pangram: every char one column, 38 total.
    let line = run_marked(id, cols, rows, &format!("echo 'CZ={}'", CZECH), "CZ=");
    assert_eq!(&line[3..], CZECH);
    assert_eq!(utf8_width(CZECH), 38);

    // Wrap exactly at a wide-char boundary on an 80-column terminal.
    cbo_session_resize(id, 80, 24);
    std::thread::sleep(Duration::from_millis(300));
    let line = run_marked(id, 80, 24, "echo \"W80=$(tput cols)\"", "W80=");
    assert_eq!(
        line, "W80=80",
        "remote pty must be 80 columns for the wrap check"
    );
    write(
        id,
        &format!("printf '\\n%s' '{}你'; sleep 1; echo\n", "a".repeat(79)),
    );
    let (r, _l, cells) =
        wait_row(id, 80, 24, Duration::from_secs(5), |l| l == "你").expect("你 on its own row");
    assert!(r > 0);
    let prev = (r - 1) * 80;
    assert_eq!(cells[prev + 78].cp, 'a' as u32);
    assert_eq!(
        (cells[prev + 79].cp, cells[prev + 79].width),
        (0, 1),
        "col 79 left blank"
    );
    assert_eq!((cells[r * 80].cp, cells[r * 80].width), ('你' as u32, 2));
    assert_eq!(cells[r * 80 + 1].width, 0);
    assert_eq!(cursor(id), (2, r as u16, 1));

    close_and_free(id);
    assert_eq!(cbo_session_count(), 0);
}

#[test]
fn resize_reaches_the_remote_pty() {
    gate!();
    let _g = serial();
    let _sweep = Sweep;
    cbo_init();
    let id = connect_local(80, 24);
    for (n, (c, r)) in [(120u16, 40u16), (60, 20), (200, 50), (40, 12), (100, 30)]
        .into_iter()
        .enumerate()
    {
        cbo_session_resize(id, c, r);
        let i = info(id);
        assert_eq!((i.cols, i.rows), (c, r));
        std::thread::sleep(Duration::from_millis(200));
        // Unique marker per step so a stale row cannot satisfy the check.
        let marker = format!("SZ{}=", n);
        let line = run_marked(
            id,
            c as usize,
            r as usize,
            &format!("echo \"{}$(tput cols)x$(tput lines)\"", marker),
            &marker,
        );
        assert_eq!(line, format!("{}{}x{}", marker, c, r));
        std::thread::sleep(Duration::from_millis(100));
    }
    // Rapid resizes settle on the last one.
    for i in 0..10u16 {
        cbo_session_resize(id, 80 + i, 20 + i);
    }
    cbo_session_resize(id, 90, 25);
    std::thread::sleep(Duration::from_millis(300));
    let line = run_marked(
        id,
        90,
        25,
        "echo \"SZF=$(tput cols)x$(tput lines)\"",
        "SZF=",
    );
    assert_eq!(line, "SZF=90x25");
    close_and_free(id);
}

#[test]
fn keepalive_pings_at_the_configured_interval() {
    gate!();
    let _g = serial();
    let _sweep = Sweep;
    cbo_init();
    let id = connect_local(80, 24);
    assert_eq!(info(id).last_ping_ms, 0);
    cbo_session_set_keepalive(id, 1);
    let t0 = Instant::now();
    let mut pings: Vec<u64> = Vec::new();
    while t0.elapsed() < Duration::from_secs(4) {
        let p = info(id).last_ping_ms;
        if p != 0 && pings.last() != Some(&p) {
            pings.push(p);
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(
        pings.len() >= 3,
        "expected >= 3 pings in 4 s, got {:?}",
        pings
    );
    for w in pings.windows(2) {
        let gap = w[1] - w[0];
        assert!(
            (850..=1400).contains(&gap),
            "gap {} ms out of range: {:?}",
            gap,
            pings
        );
    }
    assert_eq!(cbo_session_state(id), ST_CONNECTED);

    // 0 = off: the timestamp freezes.
    cbo_session_set_keepalive(id, 0);
    std::thread::sleep(Duration::from_millis(300));
    let frozen = info(id).last_ping_ms;
    std::thread::sleep(Duration::from_millis(2200));
    assert_eq!(
        info(id).last_ping_ms,
        frozen,
        "keepalive 0 must stop pinging"
    );
    // Still alive and responsive.
    let line = run_marked(id, 80, 24, "echo ALIVE=1", "ALIVE=");
    assert_eq!(line, "ALIVE=1");
    close_and_free(id);
}

#[test]
fn close_free_and_slot_reuse() {
    gate!();
    let _g = serial();
    let _sweep = Sweep;
    cbo_init();
    let a = connect_local(80, 24);
    let b = connect_local(80, 24);
    assert_ne!(a, b);
    assert_eq!(cbo_session_count(), 2);
    let name_a = from_c(cbo_session_get_name(a));
    assert_ne!(
        name_a,
        from_c(cbo_session_get_name(b)),
        "auto names are distinct"
    );

    cbo_session_close(a);
    wait_state(a, ST_CLOSED, Duration::from_secs(10)).expect("CLOSED");
    // free is refused while CONNECTED, allowed once CLOSED.
    cbo_session_free(b);
    assert!(last_error().contains("close it first"), "{}", last_error());
    assert_eq!(cbo_session_count(), 2);
    cbo_session_free(a);
    assert_eq!(cbo_session_count(), 1);
    assert_eq!(cbo_session_state(a), ST_IDLE, "freed slot reads IDLE");
    cbo_session_free(a);
    assert!(last_error().contains("not open"));

    let c = open_local(80, 24);
    assert_eq!(c, a, "lowest free slot is reused");
    wait_state(c, ST_CONNECTED, Duration::from_secs(10)).expect("reused slot connects");
    assert_ne!(
        from_c(cbo_session_get_name(c)),
        from_c(cbo_session_get_name(b))
    );

    // reconnect: same params, back to CONNECTED with a fresh screen.
    write(c, "echo BEFORE_RECONNECT\n");
    wait_row(c, 80, 24, Duration::from_secs(5), |l| {
        l == "BEFORE_RECONNECT"
    })
    .expect("row");
    assert_eq!(cbo_session_reconnect(c), 0);
    wait_state(c, ST_CONNECTED, Duration::from_secs(10)).expect("reconnected");
    wait_shell_prompt(c);
    let line = run_marked(c, 80, 24, "echo AFTER=1", "AFTER=");
    assert_eq!(line, "AFTER=1");

    close_and_free_all();
    assert_eq!(cbo_session_count(), 0);
}

#[test]
fn error_paths() {
    gate!();
    let _g = serial();
    let _sweep = Sweep;
    cbo_init();

    let id = open("localhost", 2, &user(), None, None, 80, 24);
    assert!(id >= 0);
    wait_state(id, ST_ERROR, Duration::from_secs(10)).expect("ERROR on a closed port");
    let e = session_error(id);
    assert!(e.contains("connect to localhost:2 failed"), "{}", e);
    assert!(e.contains("refused"), "{}", e);
    cbo_session_free(id);

    let id = open("no-such-host.invalid", 22, &user(), None, None, 80, 24);
    wait_state(id, ST_ERROR, Duration::from_secs(30)).expect("ERROR on unknown host");
    let e = session_error(id);
    assert!(e.contains("cannot resolve no-such-host.invalid"), "{}", e);
    cbo_session_free(id);

    let id = open(
        "localhost",
        22,
        &user(),
        None,
        Some("/nonexistent/id_cbo"),
        80,
        24,
    );
    wait_state(id, ST_ERROR, Duration::from_secs(10)).expect("ERROR on missing key");
    let e = session_error(id);
    assert!(e.contains("authentication failed"), "{}", e);
    assert!(e.contains("/nonexistent/id_cbo"), "{}", e);
    cbo_session_free(id);

    let id = open(
        "localhost",
        22,
        "cbo-no-such-user-xyz",
        Some("wrong"),
        None,
        80,
        24,
    );
    wait_state(id, ST_ERROR, Duration::from_secs(15)).expect("ERROR for unknown user");
    let e = session_error(id);
    assert!(
        e.contains("authentication failed for cbo-no-such-user-xyz"),
        "{}",
        e
    );
    assert!(e.contains("password"), "{}", e);
    cbo_session_free(id);

    assert_eq!(cbo_session_count(), 0);
}

#[test]
fn close_during_connecting() {
    gate!();
    let _g = serial();
    let _sweep = Sweep;
    cbo_init();
    let id = open(BLACKHOLE, 22, "nobody", None, None, 80, 24);
    assert!(id >= 0);
    assert_eq!(cbo_session_state(id), ST_CONNECTING);
    cbo_session_free(id);
    assert!(last_error().contains("close it first"), "{}", last_error());
    cbo_session_close(id);
    assert_eq!(
        cbo_session_state(id),
        ST_CLOSED,
        "close while CONNECTING is immediate"
    );
    cbo_session_free(id);
    assert_eq!(cbo_session_count(), 0);
    // The abandoned worker must not flip the (now empty) slot later.
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(cbo_session_state(id), ST_IDLE);
}

#[test]
fn session_cap_of_128_against_a_black_hole() {
    gate!();
    let _g = serial();
    let _sweep = Sweep;
    cbo_init();
    assert_eq!(cbo_session_count(), 0);
    let mut ids = Vec::new();
    for i in 0..128 {
        let id = open(BLACKHOLE, 22, "nobody", None, None, 80, 24);
        assert_eq!(id, i, "slot {} : {}", i, last_error());
        ids.push(id);
    }
    assert_eq!(cbo_session_count(), 128);
    let over = open(BLACKHOLE, 22, "nobody", None, None, 80, 24);
    assert_eq!(over, -1);
    assert!(
        last_error().contains("session limit reached (128)"),
        "{}",
        last_error()
    );

    let mut out = vec![-1i32; 128];
    assert_eq!(unsafe { cbo_session_ids(out.as_mut_ptr(), 128) }, 128);
    let mut sorted = out.clone();
    sorted.sort_unstable();
    sorted.dedup();
    assert_eq!(sorted.len(), 128, "ids are distinct");
    let mut names: Vec<String> = ids
        .iter()
        .map(|&i| from_c(cbo_session_get_name(i)))
        .collect();
    names.sort();
    names.dedup();
    assert_eq!(names.len(), 128, "auto names are distinct");
    for &id in &ids {
        assert!(matches!(cbo_session_state(id), ST_CONNECTING | ST_ERROR));
    }

    for &id in &ids {
        cbo_session_close(id);
    }
    for &id in &ids {
        let t = Instant::now();
        while !matches!(cbo_session_state(id), ST_CLOSED | ST_ERROR) && t.elapsed().as_secs() < 5 {
            std::thread::sleep(Duration::from_millis(5));
        }
        cbo_session_free(id);
    }
    assert_eq!(cbo_session_count(), 0);
    let again = open(BLACKHOLE, 22, "nobody", None, None, 80, 24);
    assert_eq!(again, 0, "slot 0 reusable after freeing everything");
    cbo_session_close(again);
    cbo_session_free(again);
    assert_eq!(cbo_session_count(), 0);
}

/// Regression: sustained, highly compressible output on several sessions at
/// once used to kill the transport ("connection lost: transport read").
#[test]
fn sustained_output_on_three_sessions_stays_connected() {
    gate!();
    let _g = serial();
    let _sweep = Sweep;
    cbo_init();
    let ids: Vec<i32> = (0..3).map(|_| connect_local(80, 24)).collect();
    for &id in &ids {
        write(id, "yes | head -c 5000000; echo STREAM_DONE\n");
    }
    let t0 = Instant::now();
    for &id in &ids {
        let remaining = Duration::from_secs(60).saturating_sub(t0.elapsed());
        let found = wait_row(id, 80, 24, remaining, |l| l == "STREAM_DONE");
        assert!(
            found.is_some(),
            "session {} never printed STREAM_DONE; state {} error {:?}",
            id,
            cbo_session_state(id),
            session_error(id)
        );
        assert_eq!(
            cbo_session_state(id),
            ST_CONNECTED,
            "session {}: {}",
            id,
            session_error(id)
        );
    }
    println!("3 x 5 MB streamed in {:.1}s", t0.elapsed().as_secs_f32());
    for &id in &ids {
        let i = info(id);
        assert!(
            i.generation > 100,
            "session {} generation {}",
            id,
            i.generation
        );
    }

    // 200 MB of base64 on one session while the others idle with keepalive.
    let id = ids[0];
    for &other in &ids[1..] {
        cbo_session_set_keepalive(other, 1);
    }
    write(id, "head -c 200000000 /dev/zero | base64; echo BIG_DONE\n");
    let t1 = Instant::now();
    let mut last_gen = 0;
    while t1.elapsed() < Duration::from_secs(20) {
        assert_eq!(cbo_session_state(id), ST_CONNECTED, "{}", session_error(id));
        let g = cbo_term_generation(id);
        assert!(g >= last_gen);
        last_gen = g;
        std::thread::sleep(Duration::from_millis(250));
    }
    for &other in &ids {
        assert_eq!(
            cbo_session_state(other),
            ST_CONNECTED,
            "session {}: {}",
            other,
            session_error(other)
        );
    }
    assert!(info(ids[1]).last_ping_ms > 0, "idle sessions kept pinging");
    // Interrupt the stream and make sure the shell is still responsive.
    write(id, "\x03");
    std::thread::sleep(Duration::from_millis(500));
    let line = run_marked(id, 80, 24, "echo STILL=alive", "STILL=");
    assert_eq!(line, "STILL=alive");
    println!(
        "200 MB stream: generation {} after 20 s, session still responsive",
        last_gen
    );
}

/// Recording through a real session: typed commands land in `commands`,
/// output lines are indexed in transcripts_fts, the transcript tail is
/// ANSI-free, and the sessions row is closed on exit.
#[test]
fn real_session_is_recorded_and_searchable() {
    gate!();
    let _g = serial();
    let _sweep = Sweep;
    cbo_init();
    cbo_record_enable(1);
    assert_eq!(cbo_record_enabled(), 1);
    let id = connect_local(80, 24);
    let db_id = record::db_session_id(&session::get(id).expect("live")).expect("recorded");
    let line = run_marked(id, 80, 24, "echo REC_ONE; ls /", "REC_ONE");
    assert_eq!(line, "REC_ONE");
    run_marked(id, 80, 24, "echo 세션 이름 테스트", "세션");
    write(id, "exit\n");
    wait_state(id, ST_CLOSED, Duration::from_secs(10)).expect("closed");
    record::flush_now().expect("flush");

    let recent = serde_json::from_str::<serde_json::Value>(&from_c(cbo_recent_commands(0, 10)))
        .unwrap_or_default();
    let cmds: Vec<String> = recent
        .as_array()
        .expect("array")
        .iter()
        .filter(|c| c["session_id"] == db_id)
        .map(|c| c["cmd"].as_str().unwrap_or("").to_string())
        .collect();
    assert!(
        cmds.contains(&"echo REC_ONE; ls /".to_string()),
        "{:?}",
        cmds
    );
    assert!(
        cmds.contains(&"echo 세션 이름 테스트".to_string()),
        "{:?}",
        cmds
    );
    assert!(cmds.contains(&"exit".to_string()), "{:?}", cmds);

    let q = cs("REC_ONE");
    let k = cs("transcript");
    let hits = serde_json::from_str::<serde_json::Value>(&from_c(unsafe {
        cbo_search_bm25(q.as_ptr(), k.as_ptr(), 10)
    }))
    .unwrap_or_default();
    assert!(
        hits.as_array()
            .map(|a| a.iter().any(|h| h["session_id"] == db_id))
            .unwrap_or(false),
        "transcripts_fts finds REC_ONE for this session: {}",
        hits
    );
    let k = cs("command");
    let hits = serde_json::from_str::<serde_json::Value>(&from_c(unsafe {
        cbo_search_bm25(q.as_ptr(), k.as_ptr(), 10)
    }))
    .unwrap_or_default();
    assert!(
        hits.as_array().map(|a| !a.is_empty()).unwrap_or(false),
        "commands_fts finds REC_ONE"
    );

    let t = from_c(cbo_session_transcript(db_id as i32, 4000));
    assert!(t.contains("REC_ONE"), "{:?}", t);
    assert!(t.contains("세션 이름 테스트"), "{:?}", t);
    assert!(!t.contains('\x1b'), "ANSI stripped");
    let row: (i64, i64) = db::with(|c| {
        c.query_row(
            "SELECT end_state, ended_ms FROM sessions WHERE id = ?1",
            [db_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .map_err(db::sql_err)
    })
    .expect("row");
    assert_eq!(row.0, ST_CLOSED as i64);
    assert!(row.1 > 0);
    cbo_session_free(id);
}
