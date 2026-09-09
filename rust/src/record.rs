//! Session recording: raw io chunks, typed-command extraction, transcript
//! indexing, UI/AI events. Writers never touch sqlite directly: everything
//! is queued and flushed by a background thread (every 250 ms or 64 KB).

use std::sync::atomic::{AtomicBool, AtomicI64, AtomicUsize, Ordering};
use std::sync::{Condvar, Mutex, Once};
use std::time::Duration;

use rusqlite::{params, Connection};
use serde_json::{json, Value};

use crate::db;
use crate::session::{lock, now_ms, Session};

pub const FLUSH_INTERVAL: Duration = Duration::from_millis(250);
pub const FLUSH_BYTES: usize = 64 * 1024;
/// Lines per transcript window indexed in transcripts_fts.
pub const WINDOW_LINES: usize = 40;
pub const DEFAULT_MAX_MB: i64 = 512;
pub const MAX_COMMAND_LEN: usize = 4096;

// ------------------------------------------------------------ ANSI strip

#[derive(Clone, Copy, PartialEq, Eq)]
enum Esc {
    None,
    Intro,
    Csi,
    Osc,
    OscTerminator,
}

/// Streaming ANSI escape stripper (keeps state across chunks).
#[derive(Default)]
pub struct AnsiStripper {
    state: Option<Esc>,
    pending: Vec<u8>,
}

impl AnsiStripper {
    pub fn new() -> Self {
        Self::default()
    }

    /// Feed raw bytes; returns the plain text produced by this chunk.
    /// `\r` is dropped, `\n` and `\t` are kept, other controls removed.
    pub fn feed(&mut self, bytes: &[u8]) -> String {
        let mut state = self.state.unwrap_or(Esc::None);
        let mut out: Vec<u8> = std::mem::take(&mut self.pending);
        for &b in bytes {
            state = match state {
                Esc::None => match b {
                    0x1b => Esc::Intro,
                    b'\n' | b'\t' => {
                        out.push(b);
                        Esc::None
                    }
                    0x00..=0x1f | 0x7f => Esc::None,
                    _ => {
                        out.push(b);
                        Esc::None
                    }
                },
                Esc::Intro => match b {
                    b'[' => Esc::Csi,
                    b']' => Esc::Osc,
                    // two-byte sequences (charset selects etc.)
                    b'(' | b')' | b'#' | b'%' | b'*' | b'+' => Esc::Intro,
                    _ => Esc::None,
                },
                Esc::Csi => {
                    if (0x40..=0x7e).contains(&b) {
                        Esc::None
                    } else {
                        Esc::Csi
                    }
                }
                Esc::Osc => match b {
                    0x07 => Esc::None,
                    0x1b => Esc::OscTerminator,
                    _ => Esc::Osc,
                },
                Esc::OscTerminator => {
                    if b == b'\\' {
                        Esc::None
                    } else {
                        Esc::Osc
                    }
                }
            };
        }
        self.state = Some(state);
        // Keep an incomplete trailing UTF-8 sequence for the next chunk.
        let split = valid_utf8_prefix(&out);
        self.pending = out.split_off(split);
        String::from_utf8_lossy(&out).into_owned()
    }
}

/// Length of the longest prefix that does not end inside a multi-byte char.
fn valid_utf8_prefix(bytes: &[u8]) -> usize {
    match std::str::from_utf8(bytes) {
        Ok(_) => bytes.len(),
        Err(e) => {
            if e.error_len().is_none() {
                e.valid_up_to()
            } else {
                bytes.len()
            }
        }
    }
}

/// One-shot ANSI strip.
pub fn strip_ansi(bytes: &[u8]) -> String {
    let mut s = AnsiStripper::new();
    let mut out = s.feed(bytes);
    out.push_str(&String::from_utf8_lossy(&s.pending));
    out
}

// ------------------------------------------------------- line assembler

/// Rebuilds typed command lines from raw keyboard input.
#[derive(Default)]
pub struct LineAssembler {
    buf: Vec<u8>,
    esc: Option<Esc>,
}

impl LineAssembler {
    pub fn new() -> Self {
        Self::default()
    }

    fn pop_char(&mut self) {
        while let Some(&last) = self.buf.last() {
            self.buf.pop();
            if last & 0xC0 != 0x80 {
                break;
            }
        }
    }

    /// The partial line typed so far.
    pub fn current(&self) -> String {
        String::from_utf8_lossy(&self.buf).into_owned()
    }

    /// Feed input bytes; returns the commands committed by Enter.
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<String> {
        let mut done = Vec::new();
        let mut esc = self.esc.unwrap_or(Esc::None);
        for &b in bytes {
            esc = match esc {
                Esc::None => match b {
                    b'\r' | b'\n' => {
                        let line = String::from_utf8_lossy(&self.buf).trim().to_string();
                        self.buf.clear();
                        if !line.is_empty() {
                            done.push(truncate(&line, MAX_COMMAND_LEN));
                        }
                        Esc::None
                    }
                    0x7f | 0x08 => {
                        self.pop_char();
                        Esc::None
                    }
                    0x15 | 0x03 => {
                        // Ctrl-U clears the line; Ctrl-C abandons it.
                        self.buf.clear();
                        Esc::None
                    }
                    0x1b => Esc::Intro,
                    0x00..=0x1f => Esc::None,
                    _ => {
                        if self.buf.len() < MAX_COMMAND_LEN * 4 {
                            self.buf.push(b);
                        }
                        Esc::None
                    }
                },
                Esc::Intro => match b {
                    b'[' | b'O' => Esc::Csi,
                    _ => Esc::None,
                },
                Esc::Csi => {
                    if (0x40..=0x7e).contains(&b) {
                        Esc::None
                    } else {
                        Esc::Csi
                    }
                }
                _ => Esc::None,
            };
        }
        self.esc = Some(esc);
        done
    }
}

fn truncate(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_string();
    }
    let mut end = max;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    s[..end].to_string()
}

// ----------------------------------------------------------- recorder

/// Per-session recording state (lives inside `Session`).
pub struct Recorder {
    pub db_id: i64,
    pub host_id: i64,
    input: LineAssembler,
    stripper: AnsiStripper,
    partial: String,
    lines: Vec<String>,
    last_cmd: Option<String>,
}

impl Recorder {
    /// What the user has typed on the current line.
    pub fn typing(&self) -> String {
        self.input.current()
    }

    fn new(db_id: i64, host_id: i64) -> Self {
        Recorder {
            db_id,
            host_id,
            input: LineAssembler::new(),
            stripper: AnsiStripper::new(),
            partial: String::new(),
            lines: Vec::new(),
            last_cmd: None,
        }
    }

    fn take_window(&mut self) -> Option<String> {
        if self.lines.is_empty() {
            return None;
        }
        let text = self.lines.join("\n");
        self.lines.clear();
        Some(text)
    }
}

// --------------------------------------------------------------- queue

enum Pending {
    Chunk {
        session_id: i64,
        ts_ms: i64,
        dir: u8,
        bytes: Vec<u8>,
    },
    Command {
        session_id: i64,
        host_id: i64,
        ts_ms: i64,
        cmd: String,
        prev: Option<String>,
    },
    Transcript {
        session_id: i64,
        text: String,
    },
}

static QUEUE: Mutex<Vec<Pending>> = Mutex::new(Vec::new());
static QUEUE_BYTES: AtomicUsize = AtomicUsize::new(0);
static WAKE: Condvar = Condvar::new();
static WAKE_LOCK: Mutex<bool> = Mutex::new(false);
static ENABLED: AtomicBool = AtomicBool::new(false);
static LOADED: AtomicBool = AtomicBool::new(false);
static IO_BYTES: AtomicI64 = AtomicI64::new(-1);
static FLUSHER: Once = Once::new();
static FLUSH_LOCK: Mutex<()> = Mutex::new(());
const MAX_QUEUE_BYTES: usize = 8 * 1024 * 1024;
const MAX_WINDOW_BYTES: usize = 64 * 1024;

fn push(p: Pending, size: usize) {
    let mut queue = lock(&QUEUE);
    if QUEUE_BYTES.load(Ordering::Relaxed).saturating_add(size) > MAX_QUEUE_BYTES {
        return; // Keep a slow/full disk from exhausting terminal memory.
    }
    queue.push(p);
    let total = QUEUE_BYTES.fetch_add(size, Ordering::Relaxed) + size;
    drop(queue);
    if total >= FLUSH_BYTES {
        wake();
    }
}

fn wake() {
    *lock(&WAKE_LOCK) = true;
    WAKE.notify_one();
}

/// Load the enabled flag from kv and start the flusher thread.
pub fn init() {
    if !LOADED.swap(true, Ordering::SeqCst) {
        let v = db::kv("record");
        ENABLED.store(v == "1" || v == "true", Ordering::SeqCst);
    }
    FLUSHER.call_once(|| {
        let _ = std::thread::Builder::new()
            .name("cbo-record".into())
            .spawn(|| loop {
                {
                    let guard = lock(&WAKE_LOCK);
                    let (mut g, _) = WAKE
                        .wait_timeout(guard, FLUSH_INTERVAL)
                        .unwrap_or_else(|e| e.into_inner());
                    *g = false;
                }
                let _ = flush_now();
            });
    });
}

pub fn enabled() -> bool {
    if !LOADED.load(Ordering::SeqCst) {
        init();
    }
    ENABLED.load(Ordering::SeqCst)
}

/// The flag without touching the database (usable while the DB lock is held).
pub fn enabled_cached() -> bool {
    ENABLED.load(Ordering::SeqCst)
}

pub fn set_enabled(on: bool) {
    LOADED.store(true, Ordering::SeqCst);
    ENABLED.store(on, Ordering::SeqCst);
    let _ = db::with(|c| db::kv_set(c, "record", if on { "1" } else { "0" }));
    for sess in crate::session::live() {
        if on {
            if matches!(
                sess.state(),
                crate::session::ST_CONNECTED | crate::session::ST_CONNECTING
            ) && db_session_id(&sess).is_none()
            {
                session_started(&sess);
            }
        } else {
            session_ended(&sess, sess.state());
        }
    }
    if !on {
        let _ = flush_now();
    }
}

/// Write everything queued in one transaction, then enforce the size cap.
pub fn flush_now() -> Result<(), String> {
    let _flush = lock(&FLUSH_LOCK);
    let items: Vec<Pending> = {
        let mut queue = lock(&QUEUE);
        QUEUE_BYTES.store(0, Ordering::Relaxed);
        std::mem::take(&mut *queue)
    };
    if items.is_empty() {
        return Ok(());
    }
    db::with(|conn| {
        let tx = conn.unchecked_transaction().map_err(db::sql_err)?;
        let mut added: i64 = 0;
        for it in items {
            match it {
                Pending::Chunk {
                    session_id,
                    ts_ms,
                    dir,
                    bytes,
                } => {
                    added += bytes.len() as i64;
                    tx.execute(
                        "INSERT INTO io_chunks(session_id, ts_ms, dir, bytes) VALUES (?1,?2,?3,?4)",
                        params![session_id, ts_ms, dir as i64, bytes],
                    )
                    .map_err(db::sql_err)?;
                }
                Pending::Command {
                    session_id,
                    host_id,
                    ts_ms,
                    cmd,
                    prev,
                } => {
                    tx.execute(
                        "INSERT INTO commands(session_id, host_id, ts_ms, cmd) VALUES (?1,?2,?3,?4)",
                        params![session_id, host_id, ts_ms, cmd],
                    )
                    .map_err(db::sql_err)?;
                    let id = tx.last_insert_rowid();
                    tx.execute(
                        "INSERT INTO commands_fts(rowid, cmd) VALUES (?1, ?2)",
                        params![id, cmd],
                    )
                    .map_err(db::sql_err)?;
                    if let Some(prev) = prev {
                        crate::assist::record_transition(&tx, host_id, &prev, &cmd)?;
                    }
                }
                Pending::Transcript { session_id, text } => {
                    tx.execute(
                        "INSERT INTO transcripts_fts(session_id, text) VALUES (?1, ?2)",
                        params![session_id, text],
                    )
                    .map_err(db::sql_err)?;
                }
            }
        }
        tx.commit().map_err(db::sql_err)?;
        if IO_BYTES.load(Ordering::Relaxed) < 0 {
            IO_BYTES.store(io_bytes(conn), Ordering::Relaxed);
        } else {
            IO_BYTES.fetch_add(added, Ordering::Relaxed);
        }
        prune(conn)
    })
}

fn io_bytes(conn: &Connection) -> i64 {
    conn.query_row(
        "SELECT COALESCE(SUM(LENGTH(bytes)), 0) FROM io_chunks",
        [],
        |r| r.get(0),
    )
    .unwrap_or(0)
}

pub fn max_bytes(conn: &Connection) -> i64 {
    let mb = db::kv_get(conn, "record.max_mb")
        .ok()
        .flatten()
        .and_then(|v| v.trim().parse::<i64>().ok())
        .unwrap_or(DEFAULT_MAX_MB);
    mb.max(0).saturating_mul(1024 * 1024)
}

/// Drop the oldest io chunks until the total is under kv "record.max_mb".
pub fn prune(conn: &Connection) -> Result<(), String> {
    let cap = max_bytes(conn);
    let mut total = io_bytes(conn);
    if total > cap {
        // Keep the newest suffix that fits, rather than deleting a fixed batch
        // (which used to delete every row in small recordings).
        let mut st = conn
            .prepare("SELECT id, LENGTH(bytes) FROM io_chunks ORDER BY id")
            .map_err(db::sql_err)?;
        let mut rows = st.query([]).map_err(db::sql_err)?;
        let mut cutoff = 0i64;
        while total > cap {
            let Some(row) = rows.next().map_err(db::sql_err)? else {
                break;
            };
            cutoff = row.get(0).map_err(db::sql_err)?;
            total -= row.get::<_, i64>(1).map_err(db::sql_err)?;
        }
        drop(rows);
        drop(st);
        conn.execute("DELETE FROM io_chunks WHERE id <= ?1", [cutoff])
            .map_err(db::sql_err)?;
    }
    IO_BYTES.store(total, Ordering::Relaxed);
    Ok(())
}

// ------------------------------------------------------ session hooks

/// Create the sessions row and attach a recorder (no-op when disabled).
pub fn session_started(sess: &Session) {
    if !enabled() {
        return;
    }
    let p = &sess.params;
    let name = sess.name();
    let (cols, rows) = (
        sess.cols.load(Ordering::Relaxed),
        sess.rows.load(Ordering::Relaxed),
    );
    let mut host_id = sess.host_id.load(Ordering::Relaxed);
    let started = db::with(|c| {
        if host_id <= 0 {
            if let Some(h) = db::host_find(c, &p.user, &p.host, p.port)? {
                host_id = h.id;
            }
        }
        if host_id > 0 {
            let _ = db::host_touch(c, host_id);
        }
        db::session_start(
            c, sess.id, host_id, &name, &p.host, p.port, &p.user, cols, rows,
        )
    });
    if let Ok(db_id) = started {
        sess.host_id.store(host_id, Ordering::Relaxed);
        *lock(&sess.rec) = Some(Recorder::new(db_id, host_id));
    }
}

/// Close the sessions row; flushes the last transcript window.
pub fn session_ended(sess: &Session, end_state: i32) {
    let rec = lock(&sess.rec).take();
    if let Some(mut rec) = rec {
        if !rec.partial.is_empty() {
            let line = std::mem::take(&mut rec.partial);
            rec.lines.push(line);
        }
        if let Some(text) = rec.take_window() {
            let size = text.len();
            push(
                Pending::Transcript {
                    session_id: rec.db_id,
                    text,
                },
                size,
            );
        }
        let _ = db::with(|c| db::session_end(c, rec.db_id, end_state));
        wake();
    }
}

pub fn session_renamed(sess: &Session, name: &str) {
    if let Some(id) = db_session_id(sess) {
        let _ = db::with(|c| db::session_set_name(c, id, name));
    }
}

/// The partial command line being typed on a live session ("" if none).
pub fn typing(sess: &Session) -> String {
    lock(&sess.rec)
        .as_ref()
        .map(|r| r.typing())
        .unwrap_or_default()
}

pub fn db_session_id(sess: &Session) -> Option<i64> {
    lock(&sess.rec).as_ref().map(|r| r.db_id)
}

/// Link a live session to a host row.
pub fn set_host(sess: &Session, host_id: i64) -> Result<(), String> {
    db::with(|c| {
        if db::host_get(c, host_id)?.is_none() {
            return Err(format!("no host with id {}", host_id));
        }
        Ok(())
    })?;
    sess.host_id.store(host_id, Ordering::Relaxed);
    let db_id = {
        let mut g = lock(&sess.rec);
        match g.as_mut() {
            Some(r) => {
                r.host_id = host_id;
                Some(r.db_id)
            }
            None => None,
        }
    };
    db::with(|c| {
        if db::host_get(c, host_id)?.is_none() {
            return Err(format!("no host with id {}", host_id));
        }
        db::host_touch(c, host_id)?;
        if let Some(id) = db_id {
            db::session_set_host(c, id, host_id)?;
        }
        Ok(())
    })
}

/// Command-only learning shares the bounded queue and SQL transition storage.
pub fn learn_command(host_id: i64, cmd: String, prev: Option<String>) {
    init();
    let size = cmd.len();
    push(
        Pending::Command {
            session_id: 0,
            host_id,
            ts_ms: now_ms() as i64,
            cmd,
            prev,
        },
        size,
    );
}

/// Bytes typed by the user (called from cbo_session_write).
pub fn on_input(sess: &Session, bytes: &[u8]) {
    let mut g = lock(&sess.rec);
    if !enabled_cached() {
        *g = None;
        return;
    }
    let Some(rec) = g.as_mut() else {
        return;
    };
    let ts = now_ms() as i64;
    push(
        Pending::Chunk {
            session_id: rec.db_id,
            ts_ms: ts,
            dir: 0,
            bytes: bytes.to_vec(),
        },
        bytes.len(),
    );
    for cmd in rec.input.feed(bytes) {
        let size = cmd.len();
        let prev = rec.last_cmd.replace(cmd.clone());
        push(
            Pending::Command {
                session_id: rec.db_id,
                host_id: rec.host_id,
                ts_ms: ts,
                cmd,
                prev,
            },
            size,
        );
    }
}

/// Bytes received from the remote side (called from the ssh pump loop).
pub fn on_output(sess: &Session, bytes: &[u8]) {
    let mut g = lock(&sess.rec);
    if !enabled_cached() {
        *g = None;
        return;
    }
    let Some(rec) = g.as_mut() else {
        return;
    };
    push(
        Pending::Chunk {
            session_id: rec.db_id,
            ts_ms: now_ms() as i64,
            dir: 1,
            bytes: bytes.to_vec(),
        },
        bytes.len(),
    );
    let text = rec.stripper.feed(bytes);
    if text.is_empty() {
        return;
    }
    rec.partial.push_str(&text);
    if !rec.partial.contains('\n') {
        if rec.partial.len() >= MAX_WINDOW_BYTES {
            let text = std::mem::take(&mut rec.partial);
            let size = text.len();
            push(
                Pending::Transcript {
                    session_id: rec.db_id,
                    text,
                },
                size,
            );
        }
        return;
    }
    let text = std::mem::take(&mut rec.partial);
    let mut parts = text.rsplitn(2, '\n');
    let rest = parts.next().unwrap_or("").to_string();
    for part in parts.next().unwrap_or("").split('\n') {
        let line = part.trim_end().to_string();
        if !line.trim().is_empty() {
            rec.lines.push(line);
        }
    }
    rec.partial = rest;
    if rec.lines.len() >= WINDOW_LINES {
        if let Some(text) = rec.take_window() {
            let size = text.len();
            push(
                Pending::Transcript {
                    session_id: rec.db_id,
                    text,
                },
                size,
            );
        }
    }
}

// --------------------------------------------------------------- events

/// Store a UI/AI/note/nav event; "ai" also lands in ai_messages. Returns id.
pub fn event(kind: &str, scene: &str, action: &str, data_json: &str) -> Result<i64, String> {
    if !enabled() {
        return Ok(0);
    }
    let kind = kind.trim().to_ascii_lowercase();
    if kind.is_empty() {
        return Err("kind is required".into());
    }
    let ts = now_ms() as i64;
    let data: Value = serde_json::from_str(data_json).unwrap_or(Value::Null);
    let data_text = if data_json.trim().is_empty() {
        String::new()
    } else {
        data_json.to_string()
    };
    let id = db::with(|c| {
        c.execute(
            "INSERT INTO events(ts_ms, kind, scene, action, data_json) VALUES (?1,?2,?3,?4,?5)",
            params![ts, kind, scene, action, data_text],
        )
        .map_err(db::sql_err)?;
        let id = c.last_insert_rowid();
        c.execute(
            "INSERT INTO events_fts(rowid, action, data) VALUES (?1, ?2, ?3)",
            params![id, action, flat_json(&data)],
        )
        .map_err(db::sql_err)?;
        if kind == "ai" {
            let s = |k: &str| {
                data.get(k)
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string()
            };
            let content = s("content");
            if !content.is_empty() {
                c.execute(
                    "INSERT INTO ai_messages(ts_ms, provider, model, role, content, session_id, scene)
                     VALUES (?1,?2,?3,?4,?5,?6,?7)",
                    params![
                        ts,
                        s("provider"),
                        s("model"),
                        s("role"),
                        content,
                        data.get("session_id").and_then(|v| v.as_i64()).unwrap_or(0),
                        scene
                    ],
                )
                .map_err(db::sql_err)?;
                let aid = c.last_insert_rowid();
                c.execute(
                    "INSERT INTO ai_fts(rowid, content) VALUES (?1, ?2)",
                    params![aid, content],
                )
                .map_err(db::sql_err)?;
            }
        }
        if kind == "ui" || kind == "nav" {
            crate::patterns::observe(c, &kind, scene, action, ts)?;
        }
        Ok(id)
    })?;
    Ok(id)
}

/// Flatten JSON into searchable words ("key value key value").
fn flat_json(v: &Value) -> String {
    let mut out = String::new();
    fn walk(v: &Value, out: &mut String) {
        match v {
            Value::Object(m) => {
                for (k, v) in m {
                    out.push_str(k);
                    out.push(' ');
                    walk(v, out);
                }
            }
            Value::Array(a) => a.iter().for_each(|v| walk(v, out)),
            Value::String(s) => {
                out.push_str(s);
                out.push(' ');
            }
            Value::Null => {}
            other => {
                out.push_str(&other.to_string());
                out.push(' ');
            }
        }
    }
    walk(v, &mut out);
    out.trim().to_string()
}

// -------------------------------------------------------------- queries

/// ANSI-stripped output tail of a recorded session (newest `max_bytes`).
pub fn transcript(
    conn: &Connection,
    session_db_id: i64,
    max_bytes: usize,
) -> Result<String, String> {
    let mut st = conn
        .prepare("SELECT bytes FROM io_chunks WHERE session_id = ?1 AND dir = 1 ORDER BY id DESC")
        .map_err(db::sql_err)?;
    let rows = st
        .query_map(params![session_db_id], |r| r.get::<_, Vec<u8>>(0))
        .map_err(db::sql_err)?;
    let mut chunks: Vec<Vec<u8>> = Vec::new();
    let mut total = 0usize;
    // Over-read a little so escape sequences cut at the boundary get resolved.
    let budget = max_bytes.saturating_mul(2).max(4096);
    for row in rows {
        let b = row.map_err(db::sql_err)?;
        total += b.len();
        chunks.push(b);
        if total >= budget {
            break;
        }
    }
    chunks.reverse();
    let raw: Vec<u8> = chunks.concat();
    let text = strip_ansi(&raw);
    Ok(tail_chars(&text, max_bytes))
}

fn tail_chars(s: &str, max_bytes: usize) -> String {
    if s.len() <= max_bytes {
        return s.to_string();
    }
    let mut start = s.len() - max_bytes;
    while !s.is_char_boundary(start) {
        start += 1;
    }
    s[start..].to_string()
}

/// Newest commands first: [{id, ts_ms, session_id, host_id, cmd}].
pub fn recent_commands(
    conn: &Connection,
    host_id: i64,
    limit: usize,
) -> Result<Vec<Value>, String> {
    let sql = if host_id > 0 {
        "SELECT id, ts_ms, session_id, host_id, cmd FROM commands WHERE host_id = ?1 ORDER BY id DESC LIMIT ?2"
    } else {
        "SELECT id, ts_ms, session_id, host_id, cmd FROM commands WHERE ?1 >= 0 ORDER BY id DESC LIMIT ?2"
    };
    let mut st = conn.prepare(sql).map_err(db::sql_err)?;
    let rows = st
        .query_map(params![host_id, limit as i64], |r| {
            Ok(json!({
                "id": r.get::<_, i64>(0)?, "ts_ms": r.get::<_, i64>(1)?,
                "session_id": r.get::<_, i64>(2)?, "host_id": r.get::<_, i64>(3)?,
                "cmd": r.get::<_, String>(4)?,
            }))
        })
        .map_err(db::sql_err)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(db::sql_err)
}

/// Most used commands: [{cmd, count}].
pub fn top_commands(conn: &Connection, limit: usize) -> Result<Vec<Value>, String> {
    let mut st = conn
        .prepare("SELECT cmd, COUNT(*) AS n FROM commands GROUP BY cmd ORDER BY n DESC, MAX(ts_ms) DESC LIMIT ?1")
        .map_err(db::sql_err)?;
    let rows = st
        .query_map(params![limit as i64], |r| {
            Ok(json!({"cmd": r.get::<_, String>(0)?, "count": r.get::<_, i64>(1)?}))
        })
        .map_err(db::sql_err)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(db::sql_err)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pruning_preserves_newest_rows_and_handles_zero_and_overflow() {
        let conn = db::open_memory().unwrap();
        db::kv_set(&conn, "record.max_mb", "1").unwrap();
        for i in 1..=3 {
            conn.execute(
                "INSERT INTO io_chunks(session_id, ts_ms, dir, bytes) VALUES (1, ?1, 1, ?2)",
                params![i, vec![b'x'; 512 * 1024]],
            )
            .unwrap();
        }
        prune(&conn).unwrap();
        assert_eq!(io_bytes(&conn), 1024 * 1024);
        assert_eq!(
            conn.query_row("SELECT MIN(ts_ms) FROM io_chunks", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            2
        );
        db::kv_set(&conn, "record.max_mb", "9223372036854775807").unwrap();
        assert_eq!(max_bytes(&conn), i64::MAX);
        db::kv_set(&conn, "record.max_mb", "0").unwrap();
        prune(&conn).unwrap();
        assert_eq!(io_bytes(&conn), 0);
    }

    #[test]
    fn assembler_commits_on_enter_and_edits() {
        let mut a = LineAssembler::new();
        assert!(a.feed(b"git sta").is_empty());
        assert_eq!(a.feed(b"tus\r"), vec!["git status".to_string()]);
        assert_eq!(a.feed(b"lss\x7f -la\r"), vec!["ls -la".to_string()]);
        assert_eq!(a.feed(b"wrong\x15echo ok\r"), vec!["echo ok".to_string()]);
        assert_eq!(
            a.feed(b"abandon\x03echo two\r"),
            vec!["echo two".to_string()]
        );
        assert!(a.feed(b"\r\r\n").is_empty(), "empty lines are not commands");
        assert_eq!(a.feed(b"   spaced   \r"), vec!["spaced".to_string()]);
    }

    #[test]
    fn assembler_current_tracks_edits() {
        let mut a = LineAssembler::new();
        a.feed(b"gi");
        assert_eq!(a.current(), "gi");
        a.feed(b"t");
        a.feed(&[0x7f]);
        a.feed(b"t st");
        assert_eq!(a.current(), "git st");
        a.feed(b"\xed\x95\x9c"); // 한 in two chunks
        a.feed(b"\xea\xb8\x80"); // 글
        assert_eq!(a.current(), "git st한글");
        a.feed(&[0x7f]);
        assert_eq!(a.current(), "git st한");
        a.feed(b"\x1b[D"); // arrow key ignored
        assert_eq!(a.current(), "git st한");
        assert_eq!(a.feed(b"\r"), vec!["git st한".to_string()]);
        assert_eq!(a.current(), "");
        a.feed(b"abc");
        a.feed(&[0x03]);
        assert_eq!(a.current(), "", "Ctrl-C resets");
        a.feed(b"xyz");
        a.feed(&[0x15]);
        assert_eq!(a.current(), "", "Ctrl-U resets");
    }

    #[test]
    fn assembler_ignores_arrow_keys_and_handles_cjk_backspace() {
        let mut a = LineAssembler::new();
        assert_eq!(a.feed(b"\x1b[A\x1b[B\x1bOAls\r"), vec!["ls".to_string()]);
        let cmd = "echo 세션 이름";
        let mut bytes = cmd.as_bytes().to_vec();
        bytes.extend_from_slice("X".as_bytes());
        bytes.push(0x7f); // remove X
        bytes.push(0x7f); // remove 름 (3 bytes) as one char
        bytes.extend_from_slice("름\r".as_bytes());
        assert_eq!(a.feed(&bytes), vec!["echo 세션 이름".to_string()]);
        // Split across chunks mid-UTF-8.
        let b = "你好".as_bytes();
        assert!(a.feed(&b[..2]).is_empty());
        assert_eq!(a.feed(&b[2..]).len(), 0);
        assert_eq!(a.feed(b"\r"), vec!["你好".to_string()]);
    }

    #[test]
    fn strip_ansi_removes_escapes_and_keeps_text() {
        let raw = b"\x1b[31mred\x1b[0m \x1b]0;title\x07plain\r\n\x1b[2K\x1b[Hyou \xe4\xbd\xa0\t!";
        assert_eq!(strip_ansi(raw), "red plain\nyou 你\t!");
        let mut s = AnsiStripper::new();
        let a = s.feed(b"ab\x1b[3");
        let b = s.feed(b"1mcd\xe4\xbd");
        let c = s.feed(b"\xa0e");
        assert_eq!(format!("{}{}{}", a, b, c), "abcd你e");
    }

    #[test]
    fn tail_respects_char_boundaries() {
        assert_eq!(tail_chars("abc你好", 4), "好", "never starts inside a char");
        assert_eq!(tail_chars("abc你好", 6), "你好");
        assert_eq!(tail_chars("abc", 10), "abc");
    }

    #[test]
    fn flat_json_words() {
        let v: Value = serde_json::from_str(r#"{"a":"x y","b":[1,{"c":"z"}],"d":null}"#)
            .unwrap_or(Value::Null);
        assert_eq!(flat_json(&v), "a x y b 1 c z d");
    }
}
