//! Session registry (max 128 slots), per-session state and the shared
//! mailbox between the FFI side and the SSH worker thread.

use std::sync::atomic::{
    AtomicBool, AtomicI32, AtomicI64, AtomicU16, AtomicU32, AtomicU64, Ordering,
};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::term::Term;

pub const MAX_SESSIONS: usize = 128;
pub const DEFAULT_KEEPALIVE_SECS: u32 = 15;

pub const ST_IDLE: i32 = 0;
pub const ST_CONNECTING: i32 = 1;
pub const ST_CONNECTED: i32 = 2;
pub const ST_CLOSED: i32 = 3;
pub const ST_ERROR: i32 = 4;

/// Mirror of `CboSessionInfo` in cbo.h. Layout is frozen.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CboSessionInfo {
    pub id: i32,
    pub state: i32,
    pub cols: u16,
    pub rows: u16,
    pub port: u16,
    pub _pad: u16,
    pub created_ms: u64,
    pub last_activity_ms: u64,
    pub last_ping_ms: u64,
    pub generation: u64,
    pub name: [u8; 64],
    pub host: [u8; 128],
    pub user: [u8; 64],
}

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Copy a UTF-8 string into a fixed C buffer, NUL terminated, never splitting
/// a multi-byte sequence.
pub fn fill_cstr(dst: &mut [u8], src: &str) {
    dst.fill(0);
    if dst.is_empty() {
        return;
    }
    let max = dst.len() - 1;
    let mut end = src.len().min(max);
    while end > 0 && !src.is_char_boundary(end) {
        end -= 1;
    }
    dst[..end].copy_from_slice(&src.as_bytes()[..end]);
}

#[derive(Clone, Debug)]
pub struct ConnectParams {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: Option<String>,
    pub keypath: Option<String>,
}

pub struct Session {
    pub id: i32,
    pub params: ConnectParams,
    pub state: AtomicI32,
    pub error: Mutex<String>,
    pub name: Mutex<String>,
    pub created_ms: u64,
    pub last_activity_ms: AtomicU64,
    pub last_ping_ms: AtomicU64,
    pub keepalive_secs: AtomicU32,
    pub cols: AtomicU16,
    pub rows: AtomicU16,
    /// Incremented on every (re)connect; a worker whose epoch is stale exits.
    pub epoch: AtomicU32,
    pub close_requested: AtomicBool,
    pub term: Mutex<Term>,
    /// Bytes queued for the remote side.
    pub outgoing: Mutex<Vec<u8>>,
    /// Pending pty resize (cols, rows).
    pub resize_request: Mutex<Option<(u16, u16)>>,
    /// hosts.id this session is linked to (0 = none).
    pub host_id: AtomicI64,
    /// Recording state (None when recording is off).
    pub rec: Mutex<Option<crate::record::Recorder>>,
    pub learning: Mutex<crate::learning::Learning>,
}

impl Session {
    pub fn new(id: i32, params: ConnectParams, name: String, cols: u16, rows: u16) -> Self {
        let now = now_ms();
        Session {
            id,
            params,
            state: AtomicI32::new(ST_IDLE),
            error: Mutex::new(String::new()),
            name: Mutex::new(name),
            created_ms: now,
            last_activity_ms: AtomicU64::new(now),
            last_ping_ms: AtomicU64::new(0),
            keepalive_secs: AtomicU32::new(DEFAULT_KEEPALIVE_SECS),
            cols: AtomicU16::new(cols),
            rows: AtomicU16::new(rows),
            epoch: AtomicU32::new(0),
            close_requested: AtomicBool::new(false),
            term: Mutex::new(Term::new(cols, rows)),
            outgoing: Mutex::new(Vec::new()),
            resize_request: Mutex::new(None),
            host_id: AtomicI64::new(0),
            rec: Mutex::new(None),
            learning: Mutex::new(crate::learning::Learning::default()),
        }
    }

    pub fn state(&self) -> i32 {
        self.state.load(Ordering::SeqCst)
    }

    pub fn set_state(&self, st: i32) {
        self.state.store(st, Ordering::SeqCst);
        if matches!(st, ST_CLOSED | ST_ERROR) {
            crate::record::session_ended(self, st);
        }
    }

    pub fn set_error(&self, msg: impl Into<String>) {
        *lock(&self.error) = msg.into();
        self.set_state(ST_ERROR);
    }

    pub fn error(&self) -> String {
        lock(&self.error).clone()
    }

    pub fn name(&self) -> String {
        lock(&self.name).clone()
    }

    pub fn touch(&self) {
        self.last_activity_ms.store(now_ms(), Ordering::Relaxed);
    }

    pub fn term(&self) -> MutexGuard<'_, Term> {
        lock(&self.term)
    }

    pub fn write(&self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        crate::learning::on_input(self, bytes);
        crate::record::on_input(self, bytes);
        lock(&self.outgoing).extend_from_slice(bytes);
        self.touch();
    }

    pub fn resize(&self, cols: u16, rows: u16) {
        let (cols, rows) = (cols.max(1), rows.max(1));
        self.cols.store(cols, Ordering::Relaxed);
        self.rows.store(rows, Ordering::Relaxed);
        self.term().resize(cols, rows);
        *lock(&self.resize_request) = Some((cols, rows));
    }

    /// Fill the C info struct.
    pub fn info(&self) -> CboSessionInfo {
        let mut out = CboSessionInfo {
            id: self.id,
            state: self.state(),
            cols: self.cols.load(Ordering::Relaxed),
            rows: self.rows.load(Ordering::Relaxed),
            port: self.params.port,
            _pad: 0,
            created_ms: self.created_ms,
            last_activity_ms: self.last_activity_ms.load(Ordering::Relaxed),
            last_ping_ms: self.last_ping_ms.load(Ordering::Relaxed),
            generation: self.term().generation(),
            name: [0; 64],
            host: [0; 128],
            user: [0; 64],
        };
        fill_cstr(&mut out.name, &self.name());
        fill_cstr(&mut out.host, &self.params.host);
        fill_cstr(&mut out.user, &self.params.user);
        out
    }

    /// Start (or restart) the SSH worker for this session.
    pub fn connect(self: &Arc<Self>) {
        let epoch = self.epoch.fetch_add(1, Ordering::SeqCst) + 1;
        self.close_requested.store(false, Ordering::SeqCst);
        *lock(&self.error) = String::new();
        lock(&self.outgoing).clear();
        // A reconnect while still connected: close the old recording first.
        crate::record::session_ended(self, ST_CLOSED);
        self.set_state(ST_CONNECTING);
        self.touch();
        crate::record::session_started(self);
        crate::ssh::spawn(Arc::clone(self), epoch);
    }
}

/// Lock a mutex, recovering from poisoning (a panicked worker must not take
/// the whole registry down with it).
pub fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

static REGISTRY: Mutex<Vec<Option<Arc<Session>>>> = Mutex::new(Vec::new());

fn registry() -> MutexGuard<'static, Vec<Option<Arc<Session>>>> {
    let mut g = lock(&REGISTRY);
    if g.len() < MAX_SESSIONS {
        g.resize_with(MAX_SESSIONS, || None);
    }
    g
}

pub fn get(id: i32) -> Option<Arc<Session>> {
    if id < 0 || id as usize >= MAX_SESSIONS {
        return None;
    }
    registry()[id as usize].clone()
}

pub fn live() -> Vec<Arc<Session>> {
    registry().iter().flatten().cloned().collect()
}

pub fn live_names() -> Vec<String> {
    live().iter().map(|s| s.name()).collect()
}

/// Allocate a slot and start connecting. `Err` when full.
pub fn open(params: ConnectParams, cols: u16, rows: u16) -> Result<i32, String> {
    let mut reg = registry();
    let slot = reg
        .iter()
        .position(|s| s.is_none())
        .ok_or_else(|| format!("session limit reached ({})", MAX_SESSIONS))?;
    let taken: Vec<String> = reg.iter().flatten().map(|s| s.name()).collect();
    let name = crate::names::generate(0, &taken);
    let sess = Arc::new(Session::new(slot as i32, params, name, cols, rows));
    reg[slot] = Some(Arc::clone(&sess));
    drop(reg);
    sess.connect();
    Ok(slot as i32)
}

/// Release a slot. Only CLOSED / ERROR sessions can be freed.
pub fn free(id: i32) -> Result<(), String> {
    let mut reg = registry();
    let slot = reg
        .get_mut(id as usize)
        .filter(|_| id >= 0)
        .ok_or_else(|| format!("bad session id {}", id))?;
    match slot {
        None => Err(format!("session {} not open", id)),
        Some(s) if matches!(s.state(), ST_CLOSED | ST_ERROR) => {
            // Make sure any lingering worker gives up.
            s.close_requested.store(true, Ordering::SeqCst);
            s.epoch.fetch_add(1, Ordering::SeqCst);
            *slot = None;
            Ok(())
        }
        Some(s) => Err(format!(
            "session {} is in state {}; close it first",
            id,
            s.state()
        )),
    }
}

pub fn count() -> i32 {
    registry().iter().flatten().count() as i32
}

pub fn ids() -> Vec<i32> {
    registry().iter().flatten().map(|s| s.id).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn info_layout_matches_header() {
        // 4+4+2+2+2+2 = 16, +8*4 = 48, +64+128+64 = 304
        assert_eq!(std::mem::size_of::<CboSessionInfo>(), 304);
        assert_eq!(std::mem::align_of::<CboSessionInfo>(), 8);
    }

    #[test]
    fn fill_cstr_never_splits_utf8() {
        let mut buf = [0u8; 5];
        fill_cstr(&mut buf, "你好");
        assert_eq!(&buf, &[0xE4, 0xBD, 0xA0, 0, 0]);
        fill_cstr(&mut buf, "abcdefg");
        assert_eq!(&buf, b"abcd\0");
    }
}
