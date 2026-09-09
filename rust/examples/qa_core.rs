//! QA phase 1: core acceptance tests through the C ABI, against the local
//! sshd and the live LLM providers. Every check prints what it saw so the
//! output can be pasted into docs/QA_REPORT.md.
//!
//!   cargo run --release --example qa_core -- <check> [<check> ...]
//!
//! checks: unicode fullscreen resize keepalive limits blackhole errors names
//!         search llm llm-cancel llm-badkey leak idle5m all
//! (`all` = everything except idle5m, which takes 5.5 minutes.)

use std::ffi::{CStr, CString};
use std::process::Command;
use std::time::{Duration, Instant};

use cbo_core::term::{resolve_index, ATTR_BOLD, ATTR_INVERSE, DEFAULT_BG, DEFAULT_FG, PALETTE16};
use cbo_core::*;

const ST_CONNECTING: i32 = 1;
const ST_CONNECTED: i32 = 2;
const ST_CLOSED: i32 = 3;
const ST_ERROR: i32 = 4;

const LLM_STREAMING: i32 = 1;
const LLM_DONE: i32 = 2;
const LLM_ERROR: i32 = 3;

/// A host that never answers: all connects sit in CONNECTING until the
/// 10 s connect timeout.
const BLACKHOLE: &str = "10.255.255.1";

// ---------------------------------------------------------------- helpers

fn cs(s: &str) -> CString {
    CString::new(s).unwrap_or_default()
}

fn from_c(p: *const std::ffi::c_char) -> String {
    if p.is_null() {
        return "<NULL>".into();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

fn last_error() -> String {
    from_c(cbo_last_error())
}

fn session_error(id: i32) -> String {
    from_c(cbo_session_error(id))
}

fn state_name(st: i32) -> &'static str {
    match st {
        0 => "IDLE",
        1 => "CONNECTING",
        2 => "CONNECTED",
        3 => "CLOSED",
        4 => "ERROR",
        _ => "?",
    }
}

fn user() -> String {
    std::env::var("USER").unwrap_or_else(|_| "root".into())
}

#[allow(clippy::too_many_arguments)]
fn open(
    host: &str,
    port: u16,
    user: &str,
    password: Option<&str>,
    keypath: Option<&str>,
    cols: u16,
    rows: u16,
) -> i32 {
    let h = cs(host);
    let u = cs(user);
    let p = password.map(cs);
    let k = keypath.map(cs);
    unsafe {
        cbo_session_open(
            h.as_ptr(),
            port,
            u.as_ptr(),
            p.as_ref().map(|c| c.as_ptr()).unwrap_or(std::ptr::null()),
            k.as_ref().map(|c| c.as_ptr()).unwrap_or(std::ptr::null()),
            cols,
            rows,
        )
    }
}

fn open_local(cols: u16, rows: u16) -> i32 {
    let id = open("localhost", 22, &user(), None, None, cols, rows);
    assert!(id >= 0, "open localhost failed: {}", last_error());
    id
}

fn info(id: i32) -> CboSessionInfo {
    let mut out = unsafe { std::mem::zeroed::<CboSessionInfo>() };
    let rc = unsafe { cbo_session_info(id, &mut out) };
    assert_eq!(rc, 0, "cbo_session_info({}) failed: {}", id, last_error());
    out
}

fn wait_state(id: i32, want: i32, timeout: Duration) -> Result<(), String> {
    let start = Instant::now();
    loop {
        let st = cbo_session_state(id);
        if st == want {
            return Ok(());
        }
        if st == ST_ERROR && want != ST_ERROR {
            return Err(format!("session {} ERROR: {}", id, session_error(id)));
        }
        if start.elapsed() > timeout {
            return Err(format!(
                "session {} still {} after {:?} (wanted {})",
                id,
                state_name(st),
                timeout,
                state_name(want)
            ));
        }
        std::thread::sleep(Duration::from_millis(15));
    }
}

fn write(id: i32, s: &str) {
    unsafe { cbo_session_write(id, s.as_ptr(), s.len() as u32) };
}

/// Screen as (text, cells). Continuation cells are skipped in the text.
fn screen(id: i32, cols: usize, rows: usize) -> (String, Vec<CboCell>) {
    let mut cells = vec![CboCell::default(); cols * rows];
    let n = unsafe { cbo_term_snapshot(id, cells.as_mut_ptr(), cells.len() as i32) } as usize;
    assert_eq!(
        n,
        cols * rows,
        "snapshot wrote {} cells, wanted {}",
        n,
        cols * rows
    );
    let mut text = String::new();
    for r in 0..rows {
        let mut line = String::new();
        for cl in &cells[r * cols..(r + 1) * cols] {
            match (cl.width, cl.cp) {
                (0, _) => {}
                (_, 0) => line.push(' '),
                (_, cp) => line.push(char::from_u32(cp).unwrap_or('?')),
            }
        }
        text.push_str(line.trim_end());
        text.push('\n');
    }
    (text, cells)
}

fn dump(text: &str) {
    for line in text.lines().filter(|l| !l.is_empty()) {
        println!("    | {}", line);
    }
}

/// An interactive shell on localhost with marker-based command completion.
struct Shell {
    id: i32,
    cols: u16,
    rows: u16,
    seq: u32,
}

impl Shell {
    fn connect(cols: u16, rows: u16) -> Shell {
        let id = open_local(cols, rows);
        wait_state(id, ST_CONNECTED, Duration::from_secs(20)).expect("CONNECTED");
        let mut sh = Shell {
            id,
            cols,
            rows,
            seq: 0,
        };
        // First marker doubles as "wait for the prompt".
        sh.run("true", Duration::from_secs(10));
        sh
    }

    fn screen(&self) -> (String, Vec<CboCell>) {
        screen(self.id, self.cols as usize, self.rows as usize)
    }

    /// Wait until `pred(screen_text)` holds; returns the screen or None.
    fn wait_screen(
        &self,
        timeout: Duration,
        pred: impl Fn(&str) -> bool,
    ) -> Option<(String, Vec<CboCell>)> {
        let start = Instant::now();
        let mut last_gen = u64::MAX;
        loop {
            let g = cbo_term_generation(self.id);
            if g != last_gen {
                last_gen = g;
                let (t, c) = self.screen();
                if pred(&t) {
                    return Some((t, c));
                }
            }
            if start.elapsed() > timeout {
                return None;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// Run `cmd`, wait for the end marker to appear on its own line, return
    /// the screen at that moment. The marker is quoted in the command so
    /// the echoed command line can never be mistaken for the output.
    fn run(&mut self, cmd: &str, timeout: Duration) -> (String, Vec<CboCell>) {
        self.seq += 1;
        let marker = format!("__END_{}__", self.seq);
        let typed = format!("{}; echo __EN''D_{}__\n", cmd, self.seq);
        write(self.id, &typed);
        let st = cbo_session_state(self.id);
        assert_eq!(
            st,
            ST_CONNECTED,
            "shell not CONNECTED: {}",
            session_error(self.id)
        );
        match self.wait_screen(timeout, |t| t.lines().any(|l| l.trim() == marker)) {
            Some(s) => s,
            None => {
                let (t, _) = self.screen();
                dump(&t);
                panic!("marker {} never appeared for `{}`", marker, cmd);
            }
        }
    }

    /// After a full-screen program exits: wait until the main screen (with
    /// the last command's marker) is visible again and the prompt is back.
    fn wait_main_screen(&self) {
        let marker = format!("__END_{}__", self.seq);
        if self
            .wait_screen(Duration::from_secs(8), |t| {
                t.lines().any(|l| l.trim() == marker)
                    && t.lines()
                        .rev()
                        .find(|l| !l.is_empty())
                        .is_some_and(|l| l.ends_with('%') || l.ends_with('$'))
            })
            .is_none()
        {
            let (t, _) = self.screen();
            dump(&t);
            panic!("main screen not restored");
        }
        std::thread::sleep(Duration::from_millis(100));
    }

    fn resize(&mut self, cols: u16, rows: u16) {
        cbo_session_resize(self.id, cols, rows);
        self.cols = cols;
        self.rows = rows;
    }

    fn close(self) {
        write(self.id, "exit\n");
        if wait_state(self.id, ST_CLOSED, Duration::from_secs(10)).is_err() {
            cbo_session_close(self.id);
            let _ = wait_state(self.id, ST_CLOSED, Duration::from_secs(5));
        }
        cbo_session_free(self.id);
    }
}

/// Row index whose first cell is `first`.
fn find_row(cells: &[CboCell], cols: usize, first: char) -> Option<usize> {
    (0..cells.len() / cols).find(|&r| cells[r * cols].cp == first as u32)
}

fn utf8_width(s: &str) -> i32 {
    unsafe { cbo_utf8_width(cs(s).as_ptr()) }
}

fn thread_count() -> usize {
    let out = Command::new("ps")
        .args(["-M", "-p", &std::process::id().to_string()])
        .output()
        .expect("ps -M");
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .count()
        .saturating_sub(1)
}

fn rss_kb() -> u64 {
    let out = Command::new("ps")
        .args(["-o", "rss=", "-p", &std::process::id().to_string()])
        .output()
        .expect("ps -o rss");
    String::from_utf8_lossy(&out.stdout)
        .trim()
        .parse()
        .unwrap_or(0)
}

fn close_and_free_all() {
    let mut ids = vec![0i32; 256];
    let n = unsafe { cbo_session_ids(ids.as_mut_ptr(), ids.len() as i32) } as usize;
    for &id in &ids[..n] {
        cbo_session_close(id);
    }
    for &id in &ids[..n] {
        let _ = wait_state(id, ST_CLOSED, Duration::from_secs(10));
        cbo_session_free(id);
    }
    assert_eq!(cbo_session_count(), 0, "registry not empty after cleanup");
}

// ------------------------------------------------------------------ checks

fn check_unicode() {
    println!("== unicode");
    let (cols, rows) = (100u16, 30u16);
    let mut sh = Shell::connect(cols, rows);
    let line = "你好世界 안녕하세요 こんにちは Příliš žluťoučký kůň úpěl ďábelské ódy";
    let (text, cells) = sh.run(&format!("echo {}", line), Duration::from_secs(5));
    dump(&text);
    let row = find_row(&cells, cols as usize, '你').expect("output row starting with 你");
    let base = row * cols as usize;
    let mut prefix = String::new();
    let mut wide = 0;
    let mut narrow = 0;
    for ch in line.chars() {
        let col = utf8_width(&prefix) as usize;
        let want_w = unicode_width_of(ch);
        let cell = cells[base + col];
        assert_eq!(
            cell.cp, ch as u32,
            "col {}: expected {:?} (U+{:04X}) got U+{:04X}",
            col, ch, ch as u32, cell.cp
        );
        assert_eq!(cell.width as usize, want_w, "{:?} width", ch);
        if want_w == 2 {
            let cont = cells[base + col + 1];
            assert_eq!(cont.width, 0, "{:?} continuation width", ch);
            assert_eq!(cont.cp, 0, "{:?} continuation cp", ch);
            wide += 1;
        } else {
            narrow += 1;
        }
        prefix.push(ch);
    }
    let total = utf8_width(line);
    assert_eq!(total, 69, "cbo_utf8_width of the line");
    let (cx, cy) = {
        let (mut x, mut y, mut v) = (0u16, 0u16, 0u8);
        unsafe { cbo_term_cursor(sh.id, &mut x, &mut y, &mut v) };
        (x, y)
    };
    println!(
        "  {} wide glyphs (width 2 + 0), {} narrow (width 1), line width {} cols, cursor at ({}, {})",
        wide, narrow, total, cx, cy
    );
    for czech in ['Ř', 'ž', 'ť', 'ů', 'ň', 'ú', 'ě', 'ď', 'á', 'ó', 'č', 'é'] {
        assert_eq!(utf8_width(&czech.to_string()), 1, "{:?}", czech);
    }
    assert_eq!(utf8_width("你好世界"), 8);
    assert_eq!(utf8_width("Příliš žluťoučký kůň úpěl ďábelské ódy"), 38);
    println!("  Czech letters width 1, 你好世界=8, Czech pangram=38 (checklist 3.4/3.7)");

    // Combining mark folds into the base cell (checklist 3.6).
    let (text, cells) = sh.run("printf 'a\\xcc\\x81b\\n'", Duration::from_secs(5));
    let row = text
        .lines()
        .position(|l| l.starts_with("a\u{301}b") || l.starts_with("áb") || l.starts_with("ab"))
        .expect("combining row");
    let base = row * cols as usize;
    println!(
        "  combining: cells = {:?}",
        cells[base..base + 3]
            .iter()
            .map(|c| (c.cp, c.width))
            .collect::<Vec<_>>()
    );
    assert_eq!(cells[base].cp, 'a' as u32);
    assert_eq!(
        cells[base + 1].cp,
        'b' as u32,
        "combining acute must not take a cell"
    );

    // Colours and attributes.
    let cmd = r"printf '\e[1;32mBOLD GREEN\e[0m \e[7minverse\e[0m \e[38;5;208m256orange\e[0m \e[38;2;255;0;128mtruecolor\e[0m\n'";
    let (text, cells) = sh.run(cmd, Duration::from_secs(5));
    let row = text
        .lines()
        .position(|l| l.starts_with("BOLD GREEN inverse"))
        .expect("colour row");
    let base = row * cols as usize;
    let seg = |s: &str, from: usize| -> Vec<CboCell> {
        cells[base + from..base + from + s.chars().count()].to_vec()
    };
    for c in seg("BOLD GREEN", 0) {
        assert_eq!(c.fg, PALETTE16[10], "bold green -> bright green");
        assert_ne!(c.attr & ATTR_BOLD, 0);
        assert_eq!(c.bg, DEFAULT_BG);
    }
    for c in seg("inverse", 11) {
        assert_ne!(c.attr & ATTR_INVERSE, 0);
        assert_eq!(c.fg, DEFAULT_BG, "inverse swaps fg");
        assert_eq!(c.bg, DEFAULT_FG, "inverse swaps bg");
    }
    for c in seg("256orange", 19) {
        assert_eq!(c.fg, resolve_index(208), "256-colour 208");
        assert_eq!(c.fg, 0xFF8700);
    }
    for c in seg("truecolor", 29) {
        assert_eq!(c.fg, 0xFF0080, "truecolor 255,0,128");
    }
    let after = cells[base + 38];
    assert_eq!(after.fg, DEFAULT_FG, "attrs reset after \\e[0m");
    assert_eq!(after.attr, 0);
    println!(
        "  colours: bold green={:06X}+BOLD, inverse fg/bg swapped, 208={:06X}, truecolor={:06X}",
        PALETTE16[10],
        resolve_index(208),
        0xFF0080
    );
    sh.close();
    assert_eq!(cbo_session_count(), 0);
    println!("PASS unicode");
}

fn unicode_width_of(ch: char) -> usize {
    utf8_width(&ch.to_string()) as usize
}

fn check_fullscreen() {
    println!("== fullscreen");
    let (cols, rows) = (100u16, 30u16);
    let mut sh = Shell::connect(cols, rows);
    let (before, _) = sh.run("echo BEFORE_ALT", Duration::from_secs(5));
    assert!(before.contains("BEFORE_ALT"));

    // vim: alt screen, insert, quit.
    let g0 = cbo_term_generation(sh.id);
    write(sh.id, "vim\n");
    let (t, _) = sh
        .wait_screen(Duration::from_secs(8), |t| {
            t.lines().filter(|l| l.starts_with('~')).count() >= 5
        })
        .expect("vim tilde rows");
    assert!(
        !t.contains("BEFORE_ALT"),
        "alternate screen should hide the shell"
    );
    write(sh.id, "i");
    std::thread::sleep(Duration::from_millis(150));
    write(sh.id, "hello office");
    let (t, _) = sh
        .wait_screen(Duration::from_secs(5), |t| {
            t.contains("hello office") && t.contains("INSERT")
        })
        .expect("vim insert mode text");
    println!(
        "  vim: insert mode shows text, {} tilde rows",
        t.lines().filter(|l| l.starts_with('~')).count()
    );
    write(sh.id, "\x1b");
    std::thread::sleep(Duration::from_millis(200));
    write(sh.id, ":q!\n");
    // vim restores the tty with TCSAFLUSH on exit, which discards typed-ahead
    // input; a human only types after the shell is back, so wait for it.
    sh.wait_main_screen();
    let (t, _) = sh.run("echo AFTER_VIM", Duration::from_secs(8));
    assert!(t.contains("BEFORE_ALT"), "main screen restored after vim");
    assert!(
        !t.contains("hello office"),
        "alt screen content must not leak"
    );
    assert!(t.contains("AFTER_VIM"));
    let g1 = cbo_term_generation(sh.id);
    assert!(
        g1 > g0 + 5,
        "generation should bump many times ({} -> {})",
        g0,
        g1
    );
    println!("  vim: main screen restored, generation {} -> {}", g0, g1);

    // top in logging mode (plain text, lots of output).
    let (t, _) = sh.run("top -l 2 -n 5 | tail -20", Duration::from_secs(20));
    assert!(t.contains("PID") || t.contains("Processes"), "top output");
    println!(
        "  top -l 2 -n 5: ok, {} lines on screen",
        t.lines().filter(|l| !l.is_empty()).count()
    );

    // top interactive (curses, alt screen) then q.
    write(sh.id, "top -s 1 -n 5\n");
    let ok = sh
        .wait_screen(Duration::from_secs(10), |t| {
            t.contains("Processes:") || t.contains("PID")
        })
        .is_some();
    assert!(ok, "interactive top did not draw");
    std::thread::sleep(Duration::from_millis(1500));
    write(sh.id, "q");
    sh.wait_main_screen();
    let (t, _) = sh.run("echo AFTER_TOP", Duration::from_secs(8));
    assert!(t.contains("AFTER_TOP"));
    assert!(
        t.contains("__END_4__"),
        "main screen (pre-top output) restored after top"
    );
    assert!(!t.contains("Processes:"), "curses top screen must not leak");
    println!("  top (interactive): drew, q restored the shell");

    // coloured ls.
    let (t, cells) = sh.run("ls --color=always -la ~ | head -8", Duration::from_secs(8));
    let coloured = cells
        .iter()
        .filter(|c| c.cp != 0 && c.fg != DEFAULT_FG)
        .count();
    println!("  ls --color=always: {} coloured cells", coloured);
    assert!(t.contains("total") || t.contains("drwx"), "ls output");
    let (t, cells) = sh.run(
        "CLICOLOR_FORCE=1 ls -G -la ~ | head -8",
        Duration::from_secs(8),
    );
    let coloured_g = cells
        .iter()
        .filter(|c| c.cp != 0 && c.fg != DEFAULT_FG)
        .count();
    println!("  ls -G (CLICOLOR_FORCE): {} coloured cells", coloured_g);
    assert!(t.contains("total") || t.contains("drwx"));
    assert!(
        coloured + coloured_g > 0,
        "no colour from either ls variant"
    );
    assert_eq!(cbo_session_state(sh.id), ST_CONNECTED);
    assert!(
        !last_error().contains("panic"),
        "panic seen: {}",
        last_error()
    );
    sh.close();
    println!("PASS fullscreen");
}

fn check_resize() {
    println!("== resize");
    let mut sh = Shell::connect(80, 24);
    let (t, _) = sh.run("tput cols; tput lines", Duration::from_secs(5));
    assert!(t.lines().any(|l| l.trim() == "80") && t.lines().any(|l| l.trim() == "24"));
    for (c, r) in [(120u16, 40u16), (60, 20), (200, 50), (40, 10)] {
        let g0 = cbo_term_generation(sh.id);
        sh.resize(c, r);
        let inf = info(sh.id);
        assert_eq!((inf.cols, inf.rows), (c, r), "info reflects resize");
        let (t, _) = sh.run("tput cols; tput lines", Duration::from_secs(5));
        let got_c = t.lines().any(|l| l.trim() == c.to_string());
        let got_r = t.lines().any(|l| l.trim() == r.to_string());
        if !(got_c && got_r) {
            dump(&t);
        }
        assert!(got_c, "tput cols != {}", c);
        assert!(got_r, "tput lines != {}", r);
        assert!(cbo_term_generation(sh.id) > g0);
        println!("  {}x{}: shell reports it, generation bumped", c, r);
    }
    // Rapid resizes (checklist 4.24).
    for i in 0..10u16 {
        sh.resize(60 + i * 3, 20 + i);
    }
    sh.resize(100, 30);
    let (t, _) = sh.run("tput cols; tput lines", Duration::from_secs(5));
    assert!(t.lines().any(|l| l.trim() == "100") && t.lines().any(|l| l.trim() == "30"));
    println!("  10 rapid resizes then 100x30: shell reports 100/30");
    sh.close();
    println!("PASS resize");
}

fn check_keepalive() {
    println!("== keepalive");
    let sh = Shell::connect(80, 24);
    cbo_session_set_keepalive(sh.id, 2);
    let start = Instant::now();
    let mut pings: Vec<u64> = Vec::new();
    while start.elapsed() < Duration::from_secs(10) {
        let p = info(sh.id).last_ping_ms;
        if p != 0 && pings.last() != Some(&p) {
            pings.push(p);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let gaps: Vec<u64> = pings.windows(2).map(|w| w[1] - w[0]).collect();
    println!(
        "  interval 2s, idle 10s: {} pings, gaps {:?} ms",
        pings.len(),
        gaps
    );
    assert!(pings.len() >= 3, "expected >= 3 pings, got {}", pings.len());
    assert_eq!(cbo_session_state(sh.id), ST_CONNECTED);
    cbo_session_set_keepalive(sh.id, 0);
    std::thread::sleep(Duration::from_millis(300));
    let frozen = info(sh.id).last_ping_ms;
    std::thread::sleep(Duration::from_secs(5));
    let after = info(sh.id).last_ping_ms;
    assert_eq!(frozen, after, "keepalive 0 must stop pings");
    println!("  interval 0, idle 5s: last_ping_ms frozen at {}", frozen);
    cbo_session_set_keepalive(sh.id, 1);
    std::thread::sleep(Duration::from_millis(2500));
    let resumed = info(sh.id).last_ping_ms;
    assert!(resumed > after, "keepalive should resume");
    println!("  interval 1: resumed ({} -> {})", after, resumed);
    assert_eq!(cbo_session_state(sh.id), ST_CONNECTED);
    sh.close();
    println!("PASS keepalive");
}

fn check_idle5m() {
    println!("== idle5m (keepalive 15s, 5m30s idle)");
    let mut sh = Shell::connect(80, 24);
    cbo_session_set_keepalive(sh.id, 15);
    let start = Instant::now();
    let mut pings: Vec<u64> = Vec::new();
    while start.elapsed() < Duration::from_secs(330) {
        let inf = info(sh.id);
        assert_eq!(inf.state, ST_CONNECTED, "dropped: {}", session_error(sh.id));
        if inf.last_ping_ms != 0 && pings.last() != Some(&inf.last_ping_ms) {
            pings.push(inf.last_ping_ms);
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    let gaps: Vec<u64> = pings.windows(2).map(|w| w[1] - w[0]).collect();
    println!("  {} pings in 330s; gaps ms: {:?}", pings.len(), gaps);
    assert!(pings.len() >= 20, "expected ~22 pings");
    let (t, _) = sh.run("echo STILL_ALIVE", Duration::from_secs(5));
    assert!(t.contains("STILL_ALIVE"));
    assert_eq!(cbo_session_state(sh.id), ST_CONNECTED);
    println!("  prompt responds after 5m30s idle, state CONNECTED");
    sh.close();
    println!("PASS idle5m");
}

fn check_limits() {
    println!("== limits (localhost, sequential)");
    assert_eq!(cbo_session_count(), 0);
    let t0 = Instant::now();
    let mut ids = Vec::new();
    let mut errors = Vec::new();
    loop {
        let id = open("localhost", 22, &user(), None, None, 80, 24);
        if id < 0 {
            println!("  open #{} -> -1: {:?}", ids.len() + 1, last_error());
            assert!(last_error().contains("limit"), "error not descriptive");
            break;
        }
        ids.push(id);
        if let Err(e) = wait_state(id, ST_CONNECTED, Duration::from_secs(20)) {
            errors.push(e);
        }
        if ids.len() > 200 {
            panic!("no limit");
        }
    }
    println!(
        "  {} opened in {:.1}s, {} CONNECTED, {} errors",
        ids.len(),
        t0.elapsed().as_secs_f32(),
        ids.iter()
            .filter(|&&i| cbo_session_state(i) == ST_CONNECTED)
            .count(),
        errors.len()
    );
    for e in errors.iter().take(5) {
        println!("    {}", e);
    }
    assert_eq!(ids.len(), 128);
    assert_eq!(cbo_session_count(), 128);
    let mut got = vec![-1i32; 300];
    let n = unsafe { cbo_session_ids(got.as_mut_ptr(), 300) } as usize;
    assert_eq!(n, 128);
    let mut sorted = got[..n].to_vec();
    sorted.sort_unstable();
    sorted.dedup();
    assert_eq!(
        sorted,
        (0..128).collect::<Vec<i32>>(),
        "ids are 0..127 distinct"
    );
    // Names unique among 128 live sessions.
    let mut names: Vec<String> = ids
        .iter()
        .map(|&i| from_c(cbo_session_get_name(i)))
        .collect();
    names.sort();
    let before = names.len();
    names.dedup();
    assert_eq!(
        names.len(),
        before,
        "duplicate auto names among live sessions"
    );
    println!("  128 distinct ids 0..127, 128 distinct auto names");
    if !errors.is_empty() {
        // The local sshd (launchd) resets connections above ~42 concurrent
        // ones; plain `ssh` sees the same. The slot is still taken (ERROR
        // state), so the 128 cap is exercised regardless.
        println!(
            "  note: {} sessions refused by the local sshd (environment cap); slots still count",
            errors.len()
        );
    }

    let t1 = Instant::now();
    close_and_free_all();
    println!(
        "  close+free all in {:.1}s, count={}",
        t1.elapsed().as_secs_f32(),
        cbo_session_count()
    );
    let id = open_local(80, 24);
    assert_eq!(id, 0, "lowest slot reused");
    wait_state(id, ST_CONNECTED, Duration::from_secs(20)).expect("reopen");
    cbo_session_close(id);
    wait_state(id, ST_CLOSED, Duration::from_secs(10)).expect("close");
    cbo_session_free(id);
    assert_eq!(cbo_session_count(), 0);
    println!("PASS limits");
}

fn check_blackhole() {
    println!(
        "== blackhole limit ({}, CONNECTING counts as a slot)",
        BLACKHOLE
    );
    assert_eq!(cbo_session_count(), 0);
    let threads0 = thread_count();
    let mut ids = Vec::new();
    loop {
        let id = open(BLACKHOLE, 22, "qa", None, None, 80, 24);
        if id < 0 {
            println!("  open #{} -> -1: {:?}", ids.len() + 1, last_error());
            break;
        }
        ids.push(id);
        assert!(ids.len() <= 128);
    }
    assert_eq!(ids.len(), 128);
    let connecting = ids
        .iter()
        .filter(|&&i| cbo_session_state(i) == ST_CONNECTING)
        .count();
    println!(
        "  128 slots, {} CONNECTING, threads {} -> {}",
        connecting,
        threads0,
        thread_count()
    );
    assert_eq!(cbo_session_count(), 128);
    // Free while CONNECTING must be refused; close then free must work.
    cbo_session_free(ids[0]);
    assert!(last_error().contains("close it first"), "{}", last_error());
    for &id in &ids {
        cbo_session_close(id);
        assert_eq!(
            cbo_session_state(id),
            ST_CLOSED,
            "close during CONNECTING -> CLOSED"
        );
    }
    for &id in &ids {
        cbo_session_free(id);
    }
    assert_eq!(cbo_session_count(), 0);
    let id = open(BLACKHOLE, 22, "qa", None, None, 80, 24);
    assert_eq!(id, 0, "slot 0 reusable after free");
    cbo_session_close(id);
    cbo_session_free(id);
    // The abandoned workers are blocked in connect(); they must all exit
    // once the 10 s connect timeout fires.
    let start = Instant::now();
    loop {
        let t = thread_count();
        if t <= threads0 + 1 || start.elapsed() > Duration::from_secs(25) {
            println!(
                "  abandoned workers gone after {:.1}s: threads {} (baseline {})",
                start.elapsed().as_secs_f32(),
                t,
                threads0
            );
            assert!(t <= threads0 + 1, "thread leak: {} vs {}", t, threads0);
            break;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    println!("PASS blackhole");
}

fn expect_error(label: &str, id: i32, needle: &str) {
    assert!(id >= 0, "{}: open failed: {}", label, last_error());
    let r = wait_state(id, ST_ERROR, Duration::from_secs(25));
    let msg = session_error(id);
    println!(
        "  {}: state {} -> {:?}",
        label,
        state_name(cbo_session_state(id)),
        msg
    );
    assert!(r.is_ok(), "{}: {:?}", label, r);
    assert!(!msg.is_empty(), "{}: empty error", label);
    assert!(
        msg.contains(needle),
        "{}: error should mention {:?}",
        label,
        needle
    );
    cbo_session_free(id);
}

fn check_errors() {
    println!("== errors");
    assert_eq!(cbo_session_count(), 0);
    expect_error(
        "wrong port",
        open("localhost", 2, &user(), None, None, 80, 24),
        "connect",
    );
    expect_error(
        "unknown host",
        open("no-such-host.invalid", 22, &user(), None, None, 80, 24),
        "resolve",
    );
    expect_error(
        "missing keypath",
        open(
            "localhost",
            22,
            &user(),
            None,
            Some("/nonexistent/id_qa"),
            80,
            24,
        ),
        "/nonexistent/id_qa",
    );
    expect_error(
        "wrong password, user without keys",
        open(
            "localhost",
            22,
            "cbo-no-such-user",
            Some("wrong"),
            None,
            80,
            24,
        ),
        "authentication failed",
    );
    // Wrong password for a user whose keys are in ~/.ssh: documented
    // fallback order (password, then agent, then id_*).
    let id = open(
        "localhost",
        22,
        &user(),
        Some("definitely-wrong"),
        None,
        80,
        24,
    );
    let r = wait_state(id, ST_CONNECTED, Duration::from_secs(20));
    println!(
        "  wrong password + key on disk: {} ({})",
        state_name(cbo_session_state(id)),
        r.err().unwrap_or_else(|| "fell back to ~/.ssh key".into())
    );
    cbo_session_close(id);
    let _ = wait_state(id, ST_CLOSED, Duration::from_secs(10));
    cbo_session_free(id);

    // Close/free during CONNECTING.
    let id = open(BLACKHOLE, 22, "qa", None, None, 80, 24);
    assert_eq!(cbo_session_state(id), ST_CONNECTING);
    cbo_session_close(id);
    assert_eq!(cbo_session_state(id), ST_CLOSED);
    cbo_session_free(id);
    assert_eq!(cbo_session_count(), 0);
    // Double free.
    cbo_session_free(id);
    println!("  double free -> {:?}", last_error());
    assert!(last_error().contains("not open"));
    // Write / resize / everything after free: no-ops.
    write(id, "ls\n");
    cbo_session_resize(id, 10, 10);
    assert_eq!(cbo_session_state(id), 0);
    println!("  close+free during CONNECTING ok; calls after free are no-ops");

    // Free on a live session refused.
    let sh = Shell::connect(80, 24);
    cbo_session_free(sh.id);
    assert!(last_error().contains("close it first"), "{}", last_error());
    assert_eq!(cbo_session_count(), 1);
    // Names.
    assert_eq!(
        unsafe { cbo_session_set_name(sh.id, cs("香港-辦公室").as_ptr()) },
        0
    );
    assert_eq!(from_c(cbo_session_get_name(sh.id)), "香港-辦公室");
    let long = "x".repeat(33);
    assert_eq!(
        unsafe { cbo_session_set_name(sh.id, cs(&long).as_ptr()) },
        -1
    );
    assert!(last_error().contains("32"));
    let ok32 = "y".repeat(32);
    assert_eq!(
        unsafe { cbo_session_set_name(sh.id, cs(&ok32).as_ptr()) },
        0
    );
    assert_eq!(unsafe { cbo_session_set_name(sh.id, std::ptr::null()) }, -1);
    assert_eq!(
        unsafe { cbo_session_set_name(sh.id, cs("   ").as_ptr()) },
        -1
    );
    println!("  free on CONNECTED refused; rename: utf-8 ok, 33 chars refused, NULL/blank refused");
    sh.close();

    // Bad ids on every entry point.
    for id in [-1, 128, 999, i32::MIN, i32::MAX] {
        assert_eq!(cbo_session_state(id), 0);
        assert_eq!(from_c(cbo_session_error(id)), "");
        let mut inf = unsafe { std::mem::zeroed::<CboSessionInfo>() };
        assert_eq!(unsafe { cbo_session_info(id, &mut inf) }, -1);
        assert_eq!(unsafe { cbo_session_info(id, std::ptr::null_mut()) }, -1);
        write(id, "x");
        cbo_session_resize(id, 1, 1);
        cbo_session_close(id);
        cbo_session_free(id);
        assert!(last_error().contains("bad session id") || last_error().contains("not open"));
        assert_eq!(unsafe { cbo_session_set_name(id, cs("n").as_ptr()) }, -1);
        assert_eq!(from_c(cbo_session_get_name(id)), "");
        cbo_session_set_keepalive(id, 1);
        assert_eq!(cbo_session_reconnect(id), -1);
        let mut cells = vec![CboCell::default(); 4];
        assert_eq!(unsafe { cbo_term_snapshot(id, cells.as_mut_ptr(), 4) }, 0);
        assert_eq!(unsafe { cbo_term_snapshot(id, std::ptr::null_mut(), 4) }, 0);
        assert_eq!(cbo_term_generation(id), 0);
        unsafe {
            cbo_term_cursor(
                id,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert_eq!(from_c(cbo_term_title(id)), "");
        assert_eq!(cbo_term_take_bell(id), 0);
        cbo_term_scroll(id, 5);
        assert_eq!(cbo_term_scroll_offset(id), 0);
        assert_eq!(cbo_term_scrollback_len(id), 0);
        assert_eq!(cbo_llm_state(id), LLM_ERROR);
        assert_eq!(from_c(cbo_llm_take_delta(id)), "");
        assert_eq!(from_c(cbo_llm_error(id)), "bad request id");
        cbo_llm_cancel(id);
        cbo_llm_free(id);
    }
    assert_eq!(unsafe { cbo_session_ids(std::ptr::null_mut(), 0) }, 0);
    assert_eq!(unsafe { cbo_utf8_width(std::ptr::null()) }, 0);
    assert_eq!(
        unsafe { cbo_session_search(std::ptr::null(), std::ptr::null_mut(), 0) },
        0
    );
    // Snapshot with a small cap only writes cap cells.
    let sh = Shell::connect(80, 24);
    let mut cells = vec![CboCell::default(); 7];
    assert_eq!(
        unsafe { cbo_term_snapshot(sh.id, cells.as_mut_ptr(), 7) },
        7
    );
    // Invalid UTF-8 host.
    let bad = [0xffu8, 0xfe, 0];
    let rc = unsafe {
        cbo_session_open(
            bad.as_ptr() as *const _,
            22,
            cs("u").as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            80,
            24,
        )
    };
    assert_eq!(rc, -1);
    println!("  invalid utf-8 host -> -1: {:?}", last_error());
    assert!(!last_error().contains("panic"));
    sh.close();
    assert_eq!(cbo_session_count(), 0);
    println!("  bad ids / NULL pointers on every entry point: no crash, no panic");
    println!("PASS errors");
}

fn check_names() {
    println!("== names");
    let mut all = Vec::new();
    for seed in 1..=500u64 {
        let n = from_c(cbo_name_generate(seed));
        let parts: Vec<&str> = n.split('-').collect();
        assert!(parts.len() >= 3, "{}", n);
        let nn = parts[parts.len() - 1];
        assert!(
            nn.len() == 2 && nn.bytes().all(|b| b.is_ascii_digit()),
            "{}",
            n
        );
        assert!(cbo_core::names::ADJECTIVES.contains(&parts[0]), "{}", n);
        let noun = parts[1..parts.len() - 1].join("-");
        assert!(cbo_core::names::NOUNS.contains(&noun.as_str()), "{}", n);
        assert!(n.chars().count() <= 32);
        all.push(n);
    }
    let mut uniq = all.clone();
    uniq.sort();
    uniq.dedup();
    println!(
        "  500 seeded names all `<adj>-<noun>-<NN>`; {} distinct (seeded calls are not required to be unique among themselves)",
        uniq.len()
    );
    println!("  samples: {}", all[..6].join(", "));
    // Uniqueness among live sessions.
    let mut ids = Vec::new();
    for _ in 0..40 {
        let id = open(BLACKHOLE, 22, "qa", None, None, 80, 24);
        assert!(id >= 0);
        ids.push(id);
    }
    let mut live: Vec<String> = ids
        .iter()
        .map(|&i| from_c(cbo_session_get_name(i)))
        .collect();
    let fresh = from_c(cbo_name_generate(0));
    assert!(
        !live.contains(&fresh),
        "generate(0) collided with a live name"
    );
    let before = live.len();
    live.sort();
    live.dedup();
    assert_eq!(
        live.len(),
        before,
        "duplicate auto names among 40 live sessions"
    );
    println!("  40 sessions opened back-to-back: 40 distinct auto names; generate(0) avoids them");
    let a = from_c(cbo_name_generate(0));
    let b = from_c(cbo_name_generate(0));
    println!(
        "  note: two generate(0) calls within the same ms return the same name: {} / {}",
        a, b
    );
    for &id in &ids {
        cbo_session_close(id);
        cbo_session_free(id);
    }
    assert_eq!(cbo_session_count(), 0);
    println!("PASS names");
}

fn search(q: &str) -> Vec<String> {
    let mut out = vec![0i32; 64];
    let n = unsafe { cbo_session_search(cs(q).as_ptr(), out.as_mut_ptr(), 64) } as usize;
    out[..n]
        .iter()
        .map(|&i| from_c(cbo_session_get_name(i)))
        .collect()
}

fn check_search() {
    println!("== search");
    assert_eq!(cbo_session_count(), 0);
    let fixtures = [
        ("neon-tram-07", "box.invalid", "root"),
        ("tram-jade-11", "10.255.255.1", "alice"),
        ("misty-peak-02", "tramway.invalid", "bob"),
        ("golden-junk-09", "server.invalid", "carol"),
        ("香港-辦公室", "hk.invalid", "dave"),
        ("안녕-ferry-03", "seoul.invalid", "eve"),
    ];
    let mut ids = Vec::new();
    for (name, host, user) in fixtures {
        let id = open(host, 22, user, None, None, 80, 24);
        assert!(id >= 0, "{}", last_error());
        assert_eq!(unsafe { cbo_session_set_name(id, cs(name).as_ptr()) }, 0);
        ids.push(id);
        std::thread::sleep(Duration::from_millis(3));
    }
    write(ids[3], "x"); // most recent activity
    let r = search("tram");
    println!("  tram      -> {:?}", r);
    assert_eq!(
        r,
        vec![
            "tram-jade-11".to_string(),
            "neon-tram-07".into(),
            "misty-peak-02".into()
        ],
        "name prefix > name word-start > host prefix"
    );
    let r = search("neon tr");
    println!("  'neon tr' -> {:?}", r);
    assert_eq!(
        r.first().map(String::as_str),
        Some("neon-tram-07"),
        "space-separated terms"
    );
    let r = search("안녕");
    println!("  안녕      -> {:?}", r);
    assert_eq!(r, vec!["안녕-ferry-03".to_string()]);
    let r = search("香港");
    println!("  香港      -> {:?}", r);
    assert_eq!(r, vec!["香港-辦公室".to_string()]);
    let r = search("alice@10.255");
    println!("  alice@10.255 -> {:?}", r);
    assert_eq!(r, vec!["tram-jade-11".to_string()]);
    let r = search("");
    println!("  ''        -> {:?}", r);
    assert_eq!(r.len(), 6);
    assert_eq!(
        r[0], "golden-junk-09",
        "empty query: most recent activity first"
    );
    let r = search("zzzz");
    assert!(r.is_empty());
    let r = search("   ");
    assert_eq!(r.len(), 6);
    for &id in &ids {
        cbo_session_close(id);
        let _ = wait_state(id, ST_CLOSED, Duration::from_secs(5));
        if cbo_session_state(id) == ST_CONNECTING {
            cbo_session_close(id);
        }
        cbo_session_free(id);
    }
    assert_eq!(cbo_session_count(), 0);
    println!("PASS search");
}

fn env_key(provider: &str) -> Option<String> {
    match provider {
        "openai" => std::env::var("OPENAI_API_KEY").ok(),
        "anthropic" => std::env::var("ANTHROPIC_API_KEY").ok(),
        _ => std::env::var("XAI_API_KEY")
            .or_else(|_| std::env::var("GROK_API_KEY"))
            .ok(),
    }
}

fn llm_start(provider: &str, key: &str, prompt: &str) -> i32 {
    let messages = format!(
        "[{{\"role\":\"user\",\"content\":{}}}]",
        serde_json::Value::String(prompt.to_string())
    );
    let (p, k, s, m) = (cs(provider), cs(key), cs("You are terse."), cs(&messages));
    unsafe {
        cbo_llm_start(
            p.as_ptr(),
            k.as_ptr(),
            std::ptr::null(),
            s.as_ptr(),
            m.as_ptr(),
        )
    }
}

struct StreamResult {
    text: String,
    deltas: usize,
    saw_streaming: bool,
    state: i32,
    first_delta_ms: u128,
    total_ms: u128,
}

fn drive(req: i32, timeout: Duration, mut on_delta: impl FnMut(usize)) -> StreamResult {
    let start = Instant::now();
    let mut r = StreamResult {
        text: String::new(),
        deltas: 0,
        saw_streaming: false,
        state: 0,
        first_delta_ms: 0,
        total_ms: 0,
    };
    loop {
        r.state = cbo_llm_state(req);
        if r.state == LLM_STREAMING {
            r.saw_streaming = true;
        }
        let d = from_c(cbo_llm_take_delta(req));
        if !d.is_empty() {
            if r.deltas == 0 {
                r.first_delta_ms = start.elapsed().as_millis();
            }
            r.deltas += 1;
            r.text.push_str(&d);
            on_delta(r.deltas);
        }
        if r.state == LLM_DONE || r.state == LLM_ERROR {
            r.text.push_str(&from_c(cbo_llm_take_delta(req)));
            break;
        }
        if start.elapsed() > timeout {
            cbo_llm_cancel(req);
            panic!("llm timeout");
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    r.total_ms = start.elapsed().as_millis();
    r
}

fn has_hangul(s: &str) -> bool {
    s.chars().any(|c| ('\u{AC00}'..='\u{D7A3}').contains(&c))
}

fn has_czech(s: &str) -> bool {
    s.chars()
        .any(|c| "řžťůňúěďáóčéíýšŘŽŤŮŇÚĚĎÁÓČÉÍÝŠ".contains(c))
}

fn check_llm() {
    println!("== llm streaming");
    for provider in ["xai", "openai", "anthropic"] {
        let Some(key) = env_key(provider) else {
            println!("  {}: NOT RUN (no key in env)", provider);
            continue;
        };
        let prompt = "Reply in exactly two lines. Line 1: a greeting in Korean (Hangul). \
                      Line 2: the Czech pangram 'Příliš žluťoučký kůň úpěl ďábelské ódy' followed by one short Czech sentence. \
                      Then add a third line with a one-sentence English note.";
        let req = llm_start(provider, &key, prompt);
        assert!(req >= 0, "{}: {}", provider, last_error());
        let r = drive(req, Duration::from_secs(120), |_| {});
        println!(
            "  {}: state {} after {} ms, first delta at {} ms, {} deltas, {} chars, STREAMING seen={}",
            provider,
            r.state,
            r.total_ms,
            r.first_delta_ms,
            r.deltas,
            r.text.chars().count(),
            r.saw_streaming
        );
        for line in r.text.lines().take(4) {
            println!("    > {}", line);
        }
        if r.state == LLM_ERROR {
            println!("    error: {}", from_c(cbo_llm_error(req)));
        }
        cbo_llm_free(req);
        assert_eq!(r.state, LLM_DONE, "{}", provider);
        assert!(r.saw_streaming, "{}: STREAMING never observed", provider);
        assert!(
            r.deltas >= 2,
            "{}: expected incremental deltas, got {}",
            provider,
            r.deltas
        );
        assert!(has_hangul(&r.text), "{}: no Hangul in reply", provider);
        assert!(
            has_czech(&r.text),
            "{}: no Czech diacritics in reply",
            provider
        );
        assert!(
            r.text.contains("žluťoučký"),
            "{}: pangram mangled",
            provider
        );
        assert!(std::str::from_utf8(r.text.as_bytes()).is_ok());
    }
    println!("PASS llm");
}

fn check_llm_cancel() {
    println!("== llm cancel");
    for provider in ["xai", "openai"] {
        let Some(key) = env_key(provider) else {
            println!("  {}: NOT RUN (no key)", provider);
            continue;
        };
        let req = llm_start(
            provider,
            &key,
            "Write 600 words about the history of Hong Kong trams.",
        );
        assert!(req >= 0, "{}", last_error());
        let start = Instant::now();
        let mut n = 0;
        let mut text = String::new();
        loop {
            let d = from_c(cbo_llm_take_delta(req));
            if !d.is_empty() {
                n += 1;
                text.push_str(&d);
            }
            let st = cbo_llm_state(req);
            if n >= 3 && st == LLM_STREAMING {
                break;
            }
            assert!(
                st != LLM_DONE && st != LLM_ERROR,
                "{}: finished before cancel: {}",
                provider,
                from_c(cbo_llm_error(req))
            );
            // Reasoning models stream reasoning_content (ignored) for a
            // while before the first text delta.
            assert!(start.elapsed() < Duration::from_secs(150), "no stream");
            std::thread::sleep(Duration::from_millis(5));
        }
        cbo_llm_cancel(req);
        let t_cancel = Instant::now();
        // Grace period: a line already read by the worker may land.
        std::thread::sleep(Duration::from_millis(300));
        let _ = from_c(cbo_llm_take_delta(req));
        let st_after = cbo_llm_state(req);
        let mut late = 0usize;
        let quiet_from = Instant::now();
        while quiet_from.elapsed() < Duration::from_secs(3) {
            if !from_c(cbo_llm_take_delta(req)).is_empty() {
                late += 1;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let st_final = cbo_llm_state(req);
        println!(
            "  {}: cancelled after {} deltas ({} chars); state 300ms later={}, final={}, late deltas={}, settle {} ms",
            provider,
            n,
            text.chars().count(),
            st_after,
            st_final,
            late,
            t_cancel.elapsed().as_millis()
        );
        assert_eq!(late, 0, "{}: deltas after cancel", provider);
        assert!(
            st_final == LLM_DONE || st_final == LLM_ERROR,
            "{}: state did not settle",
            provider
        );
        cbo_llm_free(req);
        assert_eq!(cbo_llm_state(req), LLM_ERROR, "freed id reads as ERROR");
    }
    println!("PASS llm-cancel");
}

fn check_llm_badkey() {
    println!("== llm bad key");
    for provider in ["xai", "openai", "anthropic"] {
        let req = llm_start(provider, "sk-definitely-not-a-key", "hi");
        assert!(req >= 0, "{}", last_error());
        let r = drive(req, Duration::from_secs(60), |_| {});
        let err = from_c(cbo_llm_error(req));
        println!(
            "  {}: state {} in {} ms: {}",
            provider,
            r.state,
            r.total_ms,
            err.replace('\n', " ")
        );
        cbo_llm_free(req);
        assert_eq!(r.state, LLM_ERROR, "{}", provider);
        assert!(
            err.starts_with("HTTP 401") || err.starts_with("HTTP 400"),
            "{}: expected HTTP 401/400 (xai answers 400), got {}",
            provider,
            err
        );
        assert!(err.len() > 12, "{}: body missing", provider);
    }
    println!("PASS llm-badkey");
}

fn check_leak() {
    println!("== leak (50 x open/close/free)");
    assert_eq!(cbo_session_count(), 0);
    // Warm up once so allocator pools / TLS are already paid for.
    let sh = Shell::connect(80, 24);
    sh.close();
    std::thread::sleep(Duration::from_millis(300));
    let (t0, m0) = (thread_count(), rss_kb());
    let start = Instant::now();
    for i in 0..50 {
        let id = open_local(80, 24);
        wait_state(id, ST_CONNECTED, Duration::from_secs(20)).expect("connect");
        write(id, "echo hi\n");
        std::thread::sleep(Duration::from_millis(30));
        cbo_session_close(id);
        wait_state(id, ST_CLOSED, Duration::from_secs(10)).expect("close");
        cbo_session_free(id);
        assert_eq!(id, 0, "slot 0 reused on iteration {}", i);
    }
    let elapsed = start.elapsed();
    std::thread::sleep(Duration::from_millis(500));
    let (t1, m1) = (thread_count(), rss_kb());
    println!(
        "  50 sessions in {:.1}s ({:.0} ms each); threads {} -> {}; rss {} -> {} KB (+{} KB)",
        elapsed.as_secs_f32(),
        elapsed.as_millis() as f32 / 50.0,
        t0,
        t1,
        m0,
        m1,
        m1 as i64 - m0 as i64
    );
    assert_eq!(cbo_session_count(), 0);
    assert!(t1 <= t0, "thread leak: {} -> {}", t0, t1);
    assert!(m1 < m0 + 40_000, "rss grew by more than 40 MB");
    println!("PASS leak");
}

fn main() {
    cbo_init();
    println!(
        "cbo_core {} pid {}",
        from_c(cbo_version()),
        std::process::id()
    );
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut checks: Vec<&str> = args.iter().map(String::as_str).collect();
    if checks.is_empty() {
        checks.push("all");
    }
    let all = [
        "unicode",
        "fullscreen",
        "resize",
        "keepalive",
        "errors",
        "names",
        "search",
        "limits",
        "blackhole",
        "leak",
        "llm",
        "llm-cancel",
        "llm-badkey",
    ];
    let mut run: Vec<&str> = Vec::new();
    for c in checks {
        if c == "all" {
            run.extend(all);
        } else {
            run.push(c);
        }
    }
    for c in run {
        let t = Instant::now();
        match c {
            "unicode" => check_unicode(),
            "fullscreen" => check_fullscreen(),
            "resize" => check_resize(),
            "keepalive" => check_keepalive(),
            "idle5m" => check_idle5m(),
            "limits" => check_limits(),
            "blackhole" => check_blackhole(),
            "errors" => check_errors(),
            "names" => check_names(),
            "search" => check_search(),
            "llm" => check_llm(),
            "llm-cancel" => check_llm_cancel(),
            "llm-badkey" => check_llm_badkey(),
            "leak" => check_leak(),
            other => panic!("unknown check {}", other),
        }
        println!("   ({:.1}s)\n", t.elapsed().as_secs_f32());
    }
    println!("QA CORE: ALL SELECTED CHECKS PASSED");
}
