//! Shared helpers for the integration tests (C ABI wrappers, gating, the
//! unicode matrix).
#![allow(dead_code)]

use std::ffi::{CStr, CString};
use std::net::{SocketAddr, TcpStream};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use cbo_core::*;

pub const ST_IDLE: i32 = 0;
pub const ST_CONNECTING: i32 = 1;
pub const ST_CONNECTED: i32 = 2;
pub const ST_CLOSED: i32 = 3;
pub const ST_ERROR: i32 = 4;

pub const LLM_PENDING: i32 = 0;
pub const LLM_STREAMING: i32 = 1;
pub const LLM_DONE: i32 = 2;
pub const LLM_ERROR: i32 = 3;

/// Never answers: connects sit in CONNECTING until the connect timeout.
pub const BLACKHOLE: &str = "10.255.255.1";

/// Tests that share the global session registry take this lock.
pub static SERIAL: Mutex<()> = Mutex::new(());

pub fn serial() -> std::sync::MutexGuard<'static, ()> {
    isolate_home();
    SERIAL.lock().unwrap_or_else(|e| e.into_inner())
}

static HOME_ONCE: std::sync::Once = std::sync::Once::new();

/// Point CBO_HOME at a fresh temp dir (once per process) so tests never
/// touch the real ~/.causewaybayoffice. Returns the directory.
pub fn isolate_home() -> std::path::PathBuf {
    HOME_ONCE.call_once(|| {
        if std::env::var_os("CBO_HOME")
            .map(|v| v.is_empty())
            .unwrap_or(true)
        {
            let dir = std::env::temp_dir().join(format!(
                "cbo-test-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_nanos())
                    .unwrap_or(0)
            ));
            std::env::set_var("CBO_HOME", &dir);
        }
    });
    std::path::PathBuf::from(std::env::var_os("CBO_HOME").unwrap_or_default())
}

/// The ssh tests run when CBO_IT=1 or when a local sshd answers on port 22.
/// CBO_IT=0 forces them off: CI runners often have an sshd listening that
/// the runner's own user cannot log in to.
pub fn ssh_enabled() -> bool {
    match std::env::var("CBO_IT").as_deref() {
        Ok("1") => return true,
        Ok("0") => return false,
        _ => {}
    }
    let addr: SocketAddr = "127.0.0.1:22".parse().expect("addr");
    TcpStream::connect_timeout(&addr, Duration::from_millis(500)).is_ok()
}

pub fn env_key(provider: &str) -> Option<String> {
    if std::env::var("CBO_LIVE").as_deref() != Ok("1") {
        return None;
    }
    let v = match provider {
        "openai" => std::env::var("OPENAI_API_KEY").ok(),
        "anthropic" => std::env::var("ANTHROPIC_API_KEY").ok(),
        _ => std::env::var("XAI_API_KEY")
            .ok()
            .or_else(|| std::env::var("GROK_API_KEY").ok()),
    };
    v.filter(|k| !k.trim().is_empty())
}

pub fn cs(s: &str) -> CString {
    CString::new(s).unwrap_or_default()
}

pub fn from_c(p: *const std::ffi::c_char) -> String {
    if p.is_null() {
        return "<NULL>".into();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

pub fn last_error() -> String {
    from_c(cbo_last_error())
}

pub fn session_error(id: i32) -> String {
    from_c(cbo_session_error(id))
}

pub fn user() -> String {
    std::env::var("USER").unwrap_or_else(|_| "root".into())
}

#[allow(clippy::too_many_arguments)]
pub fn open(
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

pub fn open_local(cols: u16, rows: u16) -> i32 {
    let id = open("localhost", 22, &user(), None, None, cols, rows);
    assert!(id >= 0, "open localhost failed: {}", last_error());
    id
}

pub fn info(id: i32) -> CboSessionInfo {
    let mut out = unsafe { std::mem::zeroed::<CboSessionInfo>() };
    let rc = unsafe { cbo_session_info(id, &mut out) };
    assert_eq!(rc, 0, "cbo_session_info({}) failed: {}", id, last_error());
    out
}

pub fn wait_state(id: i32, want: i32, timeout: Duration) -> Result<(), String> {
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
                "session {} still in state {} after {:?} (wanted {})",
                id, st, timeout, want
            ));
        }
        std::thread::sleep(Duration::from_millis(15));
    }
}

/// Startup files may take longer on a busy machine. Wait for the shell's
/// directory report and visible prompt instead of assuming a 400 ms delay.
pub fn wait_shell_prompt(id: i32) {
    let start = Instant::now();
    loop {
        if cbo_term_generation(id) > 0 && !from_c(cbo_term_cwd(id)).is_empty() && cursor(id).0 > 0 {
            return;
        }
        assert_eq!(
            cbo_session_state(id),
            ST_CONNECTED,
            "shell closed before prompt: {}",
            session_error(id)
        );
        assert!(
            start.elapsed() < Duration::from_secs(10),
            "shell prompt did not arrive within 10 seconds"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

pub fn connect_local(cols: u16, rows: u16) -> i32 {
    let id = open_local(cols, rows);
    wait_state(id, ST_CONNECTED, Duration::from_secs(10)).expect("CONNECTED");
    wait_shell_prompt(id);
    id
}

pub fn write(id: i32, s: &str) {
    unsafe { cbo_session_write(id, s.as_ptr(), s.len() as u32) };
}

/// Snapshot the screen; rows as trimmed strings (continuations skipped).
pub fn screen(id: i32, cols: usize, rows: usize) -> (Vec<String>, Vec<CboCell>) {
    let mut cells = vec![CboCell::default(); cols * rows];
    let n = unsafe { cbo_term_snapshot(id, cells.as_mut_ptr(), cells.len() as i32) } as usize;
    assert_eq!(n, cols * rows, "snapshot returned {} cells", n);
    let mut lines = Vec::with_capacity(rows);
    for r in 0..rows {
        let mut line = String::new();
        for cl in &cells[r * cols..(r + 1) * cols] {
            match (cl.width, cl.cp) {
                (0, _) => {}
                (_, 0) => line.push(' '),
                (_, cp) => line.push(char::from_u32(cp).unwrap_or('?')),
            }
        }
        lines.push(line.trim_end().to_string());
    }
    (lines, cells)
}

/// Poll until some row satisfies `pred`; returns (row index, rows, cells).
pub fn wait_row(
    id: i32,
    cols: usize,
    rows: usize,
    timeout: Duration,
    mut pred: impl FnMut(&str) -> bool,
) -> Option<(usize, Vec<String>, Vec<CboCell>)> {
    let start = Instant::now();
    while start.elapsed() < timeout {
        let (lines, cells) = screen(id, cols, rows);
        if let Some(r) = lines.iter().position(|l| pred(l)) {
            return Some((r, lines, cells));
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    None
}

pub fn cursor(id: i32) -> (u16, u16, u8) {
    let (mut x, mut y, mut v) = (0u16, 0u16, 0u8);
    unsafe { cbo_term_cursor(id, &mut x, &mut y, &mut v) };
    (x, y, v)
}

pub fn utf8_width(s: &str) -> i32 {
    unsafe { cbo_utf8_width(cs(s).as_ptr()) }
}

pub fn close_and_free(id: i32) {
    cbo_session_close(id);
    let _ = wait_state(id, ST_CLOSED, Duration::from_secs(10));
    cbo_session_free(id);
}

pub fn close_and_free_all() {
    let mut ids = vec![0i32; 128];
    let n = unsafe { cbo_session_ids(ids.as_mut_ptr(), 128) } as usize;
    for &id in &ids[..n] {
        cbo_session_close(id);
    }
    for &id in &ids[..n] {
        let _ = wait_state(id, ST_CLOSED, Duration::from_secs(10));
        cbo_session_free(id);
    }
}

/// Frees every session when dropped, so a test that panics half-way cannot
/// leak sessions into the next (serialised) test of the same process.
pub struct Sweep;

impl Drop for Sweep {
    fn drop(&mut self) {
        close_and_free_all();
    }
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

/// The unicode matrix: label, text, total columns.
pub struct Uni {
    pub label: &'static str,
    pub text: &'static str,
    pub cols: u16,
}

pub const CZECH: &str = "Příliš žluťoučký kůň úpěl ďábelské ódy";

pub const MATRIX: &[Uni] = &[
    Uni {
        label: "zh-1",
        text: "你好世界",
        cols: 8,
    },
    Uni {
        label: "zh-2",
        text: "香港銅鑼灣",
        cols: 10,
    },
    Uni {
        label: "ko-1",
        text: "안녕하세요",
        cols: 10,
    },
    Uni {
        label: "ko-2",
        text: "세션 이름",
        cols: 9,
    },
    Uni {
        label: "ja-1",
        text: "こんにちは",
        cols: 10,
    },
    Uni {
        label: "ja-2",
        text: "東京タワー",
        cols: 10,
    },
    Uni {
        label: "ja-hw",
        text: "ｶﾀｶﾅ",
        cols: 4,
    },
    Uni {
        label: "cs",
        text: CZECH,
        cols: 38,
    },
    Uni {
        label: "cs-nfd",
        text: "u\u{30A}",
        cols: 1,
    },
    Uni {
        label: "mixed",
        text: "ls 你好 안녕 こんにちは Příliš",
        cols: 30,
    },
];

/// Expected (cp, width) cells for `text`: wide chars get a 0-width
/// continuation; a combining mark folds into the previous cell.
pub fn expected_cells(text: &str) -> Vec<(u32, u8)> {
    let mut out: Vec<(u32, u8)> = Vec::new();
    for ch in text.chars() {
        match unicode_width::UnicodeWidthChar::width(ch).unwrap_or(0) {
            0 => {}
            2 => {
                out.push((ch as u32, 2));
                out.push((0, 0));
            }
            _ => out.push((ch as u32, 1)),
        }
    }
    out
}
