//! CAUSEWAYBAY OFFICE core — C ABI surface. Mirrors `include/cbo.h` exactly.
//!
//! Every `extern "C"` function is wrapped in `catch_unwind`; nothing panics
//! across the boundary. Returned `const char*` point to a thread-local buffer
//! that is valid until the next core call on the same thread.

pub mod assist;
pub mod context;
pub mod db;
pub mod display_log;
pub mod embed;
pub mod favorites;
pub mod fuzzy;
pub mod graphics;
pub mod input_history;
pub mod learning;
pub mod llm;
pub mod names;
pub mod patterns;
pub mod record;
pub mod search;
pub mod session;
pub mod ssh;
pub mod term;

use std::cell::RefCell;
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::Ordering;

pub use graphics::{CboImageInfo, CboPlacement};
pub use session::CboSessionInfo;
pub use term::CboCell;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

thread_local! {
    static RET_BUF: RefCell<CString> = RefCell::new(CString::default());
    static LAST_ERROR: RefCell<String> = const { RefCell::new(String::new()) };
}

/// Store `s` in the thread-local return buffer and hand out its pointer.
fn ret_str(s: &str) -> *const c_char {
    let owned = CString::new(s).unwrap_or_else(|_| {
        // Interior NULs cannot cross the boundary; strip them.
        let cleaned: String = s.chars().filter(|&c| c != '\0').collect();
        CString::new(cleaned).unwrap_or_default()
    });
    RET_BUF.with(|b| {
        *b.borrow_mut() = owned;
        b.borrow().as_ptr()
    })
}

fn set_last_error(msg: impl Into<String>) {
    let msg = msg.into();
    LAST_ERROR.with(|e| *e.borrow_mut() = msg);
}

fn clear_last_error() {
    LAST_ERROR.with(|e| e.borrow_mut().clear());
}

/// Borrow a C string as `&str`; `None` for NULL or invalid UTF-8.
unsafe fn cstr<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    CStr::from_ptr(p).to_str().ok()
}

/// Run `f`, converting a panic into `default` plus a recorded error.
fn guard<T>(default: T, f: impl FnOnce() -> T) -> T {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(_) => {
            set_last_error("internal panic in cbo_core");
            default
        }
    }
}

// ---- lifecycle -------------------------------------------------------------

#[no_mangle]
pub extern "C" fn cbo_init() {
    guard((), || {
        clear_last_error();
        // Touch the registries so their lazy allocation happens now.
        let _ = session::count();
        let _ = llm::get(-1);
        match db::init() {
            Ok(_) => {
                record::init();
                embed::start_worker();
            }
            Err(e) => set_last_error(format!("database unavailable: {}", e)),
        }
    });
}

/// Stop active recording and synchronously commit queued data before the UI exits.
#[no_mangle]
pub extern "C" fn cbo_shutdown() {
    guard((), || {
        embed::set_paused(true);
        for sess in session::live() {
            sess.close_requested.store(true, Ordering::SeqCst);
            sess.epoch.fetch_add(1, Ordering::SeqCst);
            sess.set_state(session::ST_CLOSED);
        }
        if let Err(e) = record::flush_now() {
            set_last_error(e);
        }
    });
}

#[no_mangle]
pub extern "C" fn cbo_version() -> *const c_char {
    guard(std::ptr::null(), || ret_str(VERSION))
}

#[no_mangle]
pub extern "C" fn cbo_last_error() -> *const c_char {
    guard(std::ptr::null(), || {
        LAST_ERROR.with(|e| ret_str(&e.borrow()))
    })
}

// ---- sessions --------------------------------------------------------------

/// # Safety
/// host/user/password/keypath must be NULL or valid NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn cbo_session_open(
    host: *const c_char,
    port: u16,
    user: *const c_char,
    password: *const c_char,
    keypath: *const c_char,
    cols: u16,
    rows: u16,
) -> i32 {
    guard(-1, || {
        clear_last_error();
        let Some(host) = cstr(host).map(str::trim).filter(|h| !h.is_empty()) else {
            set_last_error("host is required");
            return -1;
        };
        let Some(user) = cstr(user).map(str::trim).filter(|u| !u.is_empty()) else {
            set_last_error("user is required");
            return -1;
        };
        let params = session::ConnectParams {
            host: host.to_string(),
            port: if port == 0 { 22 } else { port },
            user: user.to_string(),
            password: cstr(password).filter(|p| !p.is_empty()).map(str::to_string),
            keypath: cstr(keypath)
                .filter(|k| !k.trim().is_empty())
                .map(str::to_string),
        };
        let cols = if cols == 0 { 80 } else { cols };
        let rows = if rows == 0 { 24 } else { rows };
        match session::open(params, cols, rows) {
            Ok(id) => id,
            Err(e) => {
                set_last_error(e);
                -1
            }
        }
    })
}

#[no_mangle]
pub extern "C" fn cbo_session_state(id: i32) -> i32 {
    guard(session::ST_IDLE, || match session::get(id) {
        Some(s) => s.state(),
        None => session::ST_IDLE,
    })
}

#[no_mangle]
pub extern "C" fn cbo_session_error(id: i32) -> *const c_char {
    guard(std::ptr::null(), || match session::get(id) {
        Some(s) => ret_str(&s.error()),
        None => ret_str(""),
    })
}

/// # Safety
/// `out` must be NULL or point to writable memory for one `CboSessionInfo`.
#[no_mangle]
pub unsafe extern "C" fn cbo_session_info(id: i32, out: *mut CboSessionInfo) -> i32 {
    guard(-1, || {
        if out.is_null() {
            set_last_error("out is NULL");
            return -1;
        }
        match session::get(id) {
            Some(s) => {
                std::ptr::write(out, s.info());
                0
            }
            None => {
                set_last_error(format!("bad session id {}", id));
                -1
            }
        }
    })
}

#[no_mangle]
pub extern "C" fn cbo_session_count() -> i32 {
    guard(0, session::count)
}

/// # Safety
/// `out` must be NULL or point to at least `cap` writable `int32_t`.
#[no_mangle]
pub unsafe extern "C" fn cbo_session_ids(out: *mut i32, cap: i32) -> i32 {
    guard(0, || {
        let ids = session::ids();
        if out.is_null() || cap <= 0 {
            return ids.len() as i32;
        }
        let n = ids.len().min(cap as usize);
        std::ptr::copy_nonoverlapping(ids.as_ptr(), out, n);
        n as i32
    })
}

/// # Safety
/// `bytes` must be NULL or point to `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn cbo_session_write(id: i32, bytes: *const u8, len: u32) {
    guard((), || {
        if bytes.is_null() || len == 0 {
            return;
        }
        if let Some(s) = session::get(id) {
            let slice = std::slice::from_raw_parts(bytes, len as usize);
            s.write(slice);
        }
    });
}

#[no_mangle]
pub extern "C" fn cbo_session_resize(id: i32, cols: u16, rows: u16) {
    guard((), || {
        if let Some(s) = session::get(id) {
            s.resize(cols, rows);
        }
    });
}

#[no_mangle]
pub extern "C" fn cbo_session_close(id: i32) {
    guard((), || {
        if let Some(s) = session::get(id) {
            match s.state() {
                session::ST_CONNECTED | session::ST_CONNECTING => {
                    s.close_requested.store(true, Ordering::SeqCst);
                    // A connecting worker will notice on its next check; make
                    // sure a worker stuck in a blocking phase is abandoned too.
                    if s.state() == session::ST_CONNECTING {
                        s.epoch.fetch_add(1, Ordering::SeqCst);
                        s.set_state(session::ST_CLOSED);
                    }
                }
                session::ST_IDLE => s.set_state(session::ST_CLOSED),
                _ => {}
            }
        }
    });
}

#[no_mangle]
pub extern "C" fn cbo_session_free(id: i32) {
    guard((), || {
        if let Err(e) = session::free(id) {
            set_last_error(e);
        }
    });
}

/// # Safety
/// `name` must be NULL or a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn cbo_session_set_name(id: i32, name: *const c_char) -> i32 {
    guard(-1, || {
        let Some(name) = cstr(name).map(str::trim).filter(|n| !n.is_empty()) else {
            set_last_error("name is empty or not UTF-8");
            return -1;
        };
        if name.chars().count() > 32 {
            set_last_error("name longer than 32 characters");
            return -1;
        }
        match session::get(id) {
            Some(s) => {
                *session::lock(&s.name) = name.to_string();
                record::session_renamed(&s, name);
                0
            }
            None => {
                set_last_error(format!("bad session id {}", id));
                -1
            }
        }
    })
}

#[no_mangle]
pub extern "C" fn cbo_session_get_name(id: i32) -> *const c_char {
    guard(std::ptr::null(), || match session::get(id) {
        Some(s) => ret_str(&s.name()),
        None => ret_str(""),
    })
}

#[no_mangle]
pub extern "C" fn cbo_session_set_keepalive(id: i32, seconds: u32) {
    guard((), || {
        if let Some(s) = session::get(id) {
            s.keepalive_secs.store(seconds, Ordering::Relaxed);
        }
    });
}

#[no_mangle]
pub extern "C" fn cbo_session_reconnect(id: i32) -> i32 {
    guard(-1, || match session::get(id) {
        Some(s) => {
            s.connect();
            0
        }
        None => {
            set_last_error(format!("bad session id {}", id));
            -1
        }
    })
}

// ---- terminal snapshot -----------------------------------------------------

/// # Safety
/// `out` must be NULL or point to at least `cap` writable `CboCell`.
#[no_mangle]
pub unsafe extern "C" fn cbo_term_snapshot(id: i32, out: *mut CboCell, cap: i32) -> i32 {
    guard(0, || {
        if out.is_null() || cap <= 0 {
            return 0;
        }
        match session::get(id) {
            Some(s) => {
                let slice = std::slice::from_raw_parts_mut(out, cap as usize);
                s.term().snapshot(slice) as i32
            }
            None => 0,
        }
    })
}

#[no_mangle]
pub extern "C" fn cbo_term_bracketed_paste(id: i32) -> i32 {
    guard(0, || {
        session::get(id)
            .map(|s| s.term().bracketed_paste() as i32)
            .unwrap_or(0)
    })
}

#[no_mangle]
pub extern "C" fn cbo_term_generation(id: i32) -> u64 {
    guard(0, || {
        session::get(id).map(|s| s.term().generation()).unwrap_or(0)
    })
}

/// # Safety
/// `x`, `y`, `visible` must each be NULL or point to writable memory of their type.
#[no_mangle]
pub unsafe extern "C" fn cbo_term_cursor(id: i32, x: *mut u16, y: *mut u16, visible: *mut u8) {
    guard((), || {
        let (cx, cy, vis) = match session::get(id) {
            Some(s) => s.term().cursor(),
            None => (0, 0, false),
        };
        if !x.is_null() {
            *x = cx;
        }
        if !y.is_null() {
            *y = cy;
        }
        if !visible.is_null() {
            *visible = vis as u8;
        }
    });
}

#[no_mangle]
pub extern "C" fn cbo_term_title(id: i32) -> *const c_char {
    guard(std::ptr::null(), || match session::get(id) {
        Some(s) => {
            let title = s.term().title().to_string();
            ret_str(&title)
        }
        None => ret_str(""),
    })
}

#[no_mangle]
pub extern "C" fn cbo_term_take_bell(id: i32) -> i32 {
    guard(0, || {
        session::get(id)
            .map(|s| s.term().take_bell() as i32)
            .unwrap_or(0)
    })
}

#[no_mangle]
pub extern "C" fn cbo_term_scroll(id: i32, offset: i32) {
    guard((), || {
        if let Some(s) = session::get(id) {
            s.term().set_scroll(offset);
        }
    });
}

#[no_mangle]
pub extern "C" fn cbo_term_scroll_offset(id: i32) -> i32 {
    guard(0, || {
        session::get(id)
            .map(|s| s.term().scroll_offset())
            .unwrap_or(0)
    })
}

#[no_mangle]
pub extern "C" fn cbo_term_scrollback_len(id: i32) -> i32 {
    guard(0, || {
        session::get(id)
            .map(|s| s.term().scrollback_len())
            .unwrap_or(0)
    })
}

// ---- images (kitty graphics protocol) --------------------------------------

#[no_mangle]
pub extern "C" fn cbo_term_set_cell_px(id: i32, w: u16, h: u16) {
    guard((), || {
        if let Some(s) = session::get(id) {
            s.term().set_cell_px(w, h);
        }
    });
}

/// # Safety
/// `out` must be NULL or point to at least `cap` writable `CboPlacement`.
#[no_mangle]
pub unsafe extern "C" fn cbo_term_placements(id: i32, out: *mut CboPlacement, cap: i32) -> i32 {
    guard(0, || {
        if out.is_null() || cap <= 0 {
            return 0;
        }
        let Some(s) = session::get(id) else {
            return 0;
        };
        let list = s.term().placements();
        let n = list.len().min(cap as usize);
        let slice = std::slice::from_raw_parts_mut(out, n);
        slice.copy_from_slice(&list[..n]);
        n as i32
    })
}

/// # Safety
/// `out` must be NULL or point to a writable `CboImageInfo`.
#[no_mangle]
pub unsafe extern "C" fn cbo_term_image_info(id: i32, key: u64, out: *mut CboImageInfo) -> i32 {
    guard(-1, || {
        if out.is_null() {
            set_last_error("null out");
            return -1;
        }
        match session::get(id).and_then(|s| s.term().image_info(key)) {
            Some(info) => {
                *out = info;
                0
            }
            None => {
                set_last_error(format!("no image {} in session {}", key, id));
                -1
            }
        }
    })
}

/// # Safety
/// `out` must be NULL or point to at least `cap` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn cbo_term_image_data(id: i32, key: u64, out: *mut u8, cap: i32) -> i32 {
    guard(0, || {
        if out.is_null() || cap <= 0 {
            return 0;
        }
        let Some(s) = session::get(id) else {
            return 0;
        };
        let term = s.term();
        let Some(im) = term.image(key) else {
            return 0;
        };
        let n = im.data.len().min(cap as usize);
        std::ptr::copy_nonoverlapping(im.data.as_ptr(), out, n);
        n as i32
    })
}

// ---- names / search --------------------------------------------------------

#[no_mangle]
pub extern "C" fn cbo_name_generate(seed: u64) -> *const c_char {
    guard(std::ptr::null(), || {
        let taken = session::live_names();
        ret_str(&names::generate(seed, &taken))
    })
}

/// # Safety
/// `query` must be NULL or a NUL-terminated string; `out` NULL or `cap` writable `int32_t`.
#[no_mangle]
pub unsafe extern "C" fn cbo_session_search(query: *const c_char, out: *mut i32, cap: i32) -> i32 {
    guard(0, || {
        let query = cstr(query).unwrap_or("");
        let candidates: Vec<fuzzy::Candidate> = session::live()
            .iter()
            .map(|s| fuzzy::Candidate {
                id: s.id,
                name: s.name(),
                host: s.params.host.clone(),
                user: s.params.user.clone(),
                port: s.params.port,
                last_activity_ms: s.last_activity_ms.load(Ordering::Relaxed),
            })
            .collect();
        let ids = fuzzy::search(query, &candidates);
        if out.is_null() || cap <= 0 {
            return ids.len() as i32;
        }
        let n = ids.len().min(cap as usize);
        std::ptr::copy_nonoverlapping(ids.as_ptr(), out, n);
        n as i32
    })
}

// ---- llm -------------------------------------------------------------------

/// # Safety
/// every pointer must be NULL or a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn cbo_llm_start(
    provider: *const c_char,
    api_key: *const c_char,
    model: *const c_char,
    system: *const c_char,
    messages_json: *const c_char,
) -> i32 {
    guard(-1, || {
        clear_last_error();
        let Some(provider) = cstr(provider) else {
            set_last_error("provider is required");
            return -1;
        };
        let Some(messages_json) = cstr(messages_json) else {
            set_last_error("messages_json is required");
            return -1;
        };
        let args = llm::StartArgs {
            provider: provider.to_string(),
            api_key: cstr(api_key).unwrap_or("").to_string(),
            model: cstr(model).map(str::to_string),
            system: cstr(system).map(str::to_string),
            messages_json: messages_json.to_string(),
        };
        match llm::start(args) {
            Ok(id) => id,
            Err(e) => {
                set_last_error(e);
                -1
            }
        }
    })
}

#[no_mangle]
pub extern "C" fn cbo_llm_state(req: i32) -> i32 {
    guard(llm::LLM_ERROR, || {
        llm::get(req).map(|r| r.state()).unwrap_or(llm::LLM_ERROR)
    })
}

#[no_mangle]
pub extern "C" fn cbo_llm_take_delta(req: i32) -> *const c_char {
    guard(std::ptr::null(), || match llm::get(req) {
        Some(r) => ret_str(&r.take_delta()),
        None => ret_str(""),
    })
}

#[no_mangle]
pub extern "C" fn cbo_llm_error(req: i32) -> *const c_char {
    guard(std::ptr::null(), || match llm::get(req) {
        Some(r) => ret_str(&r.error()),
        None => ret_str("bad request id"),
    })
}

#[no_mangle]
pub extern "C" fn cbo_llm_cancel(req: i32) {
    guard((), || llm::cancel(req));
}

#[no_mangle]
pub extern "C" fn cbo_llm_free(req: i32) {
    guard((), || llm::free(req));
}

// ---- utils -----------------------------------------------------------------

/// # Safety
/// `s` must be NULL or a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn cbo_utf8_width(s: *const c_char) -> i32 {
    guard(0, || match cstr(s) {
        Some(s) => unicode_width::UnicodeWidthStr::width(s) as i32,
        None => 0,
    })
}

#[no_mangle]
pub extern "C" fn cbo_now_ms() -> u64 {
    guard(0, session::now_ms)
}

// ---- persistence ------------------------------------------------------

/// Hand a JSON (or text) result to the caller, recording the error and
/// returning `fallback` when it failed.
fn ret_json(r: Result<serde_json::Value, String>, fallback: &str) -> *const c_char {
    match r {
        Ok(v) => ret_str(&v.to_string()),
        Err(e) => {
            set_last_error(e);
            ret_str(fallback)
        }
    }
}

#[no_mangle]
pub extern "C" fn cbo_data_dir() -> *const c_char {
    guard(std::ptr::null(), || {
        ret_str(&db::data_dir().to_string_lossy())
    })
}

/// # Safety
/// `key` and `value` must be valid NUL-terminated strings (value may be NULL = "").
#[no_mangle]
pub unsafe extern "C" fn cbo_kv_set(key: *const c_char, value: *const c_char) -> i32 {
    guard(-1, || {
        let Some(key) = cstr(key).map(str::trim).filter(|k| !k.is_empty()) else {
            set_last_error("key is required");
            return -1;
        };
        let value = cstr(value).unwrap_or("");
        match db::with(|c| db::kv_set(c, key, value)) {
            Ok(()) => 0,
            Err(e) => {
                set_last_error(e);
                -1
            }
        }
    })
}

/// # Safety
/// `key` must be NULL or a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn cbo_kv_get(key: *const c_char) -> *const c_char {
    guard(std::ptr::null(), || match cstr(key) {
        Some(k) => ret_str(&db::kv(k.trim())),
        None => ret_str(""),
    })
}

/// # Safety
/// `json` must be a valid NUL-terminated string containing a hosts array.
#[no_mangle]
pub unsafe extern "C" fn cbo_favorites_save(json: *const c_char) -> i32 {
    guard(-1, || {
        match db::init().and_then(|db| favorites::save(&db.dir, cstr(json).unwrap_or(""))) {
            Ok(()) => 0,
            Err(e) => {
                set_last_error(e);
                -1
            }
        }
    })
}
#[no_mangle]
pub extern "C" fn cbo_favorites_load() -> *const c_char {
    guard(std::ptr::null(), || {
        match db::init().and_then(|db| favorites::load(&db.dir)) {
            Ok(data) => ret_str(&data.unwrap_or_default()),
            Err(e) => {
                set_last_error(e);
                ret_str("")
            }
        }
    })
}

/// # Safety
/// `json` must be a valid NUL-terminated string containing a hosts array.
#[no_mangle]
pub unsafe extern "C" fn cbo_sessions_save(json: *const c_char) -> i32 {
    guard(-1, || {
        match db::init()
            .and_then(|db| favorites::save_named(&db.dir, "sessions", cstr(json).unwrap_or("")))
        {
            Ok(()) => 0,
            Err(e) => {
                set_last_error(e);
                -1
            }
        }
    })
}
#[no_mangle]
pub extern "C" fn cbo_sessions_load() -> *const c_char {
    guard(std::ptr::null(), || {
        match db::init().and_then(|db| favorites::load_named(&db.dir, "sessions")) {
            Ok(data) => ret_str(&data.unwrap_or_default()),
            Err(e) => {
                set_last_error(e);
                ret_str("")
            }
        }
    })
}

/// # Safety
/// `orientation` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn cbo_display_save(fullscreen: i32, orientation: *const c_char) -> i32 {
    guard(-1, || {
        let result = db::init().and_then(|db| {
            display_log::append(
                &db.dir.join("display.jsonl"),
                fullscreen != 0,
                cstr(orientation).unwrap_or(""),
            )
        });
        match result {
            Ok(()) => 0,
            Err(e) => {
                set_last_error(e);
                -1
            }
        }
    })
}

/// # Safety
/// Arguments must be valid NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn cbo_input_save(
    field: *const c_char,
    value: *const c_char,
    commit: i32,
) -> i32 {
    guard(-1, || {
        let result = db::with(|c| {
            input_history::save(
                c,
                cstr(field).unwrap_or(""),
                cstr(value).unwrap_or(""),
                commit != 0,
            )
        });
        match result {
            Ok(()) => 0,
            Err(e) => {
                set_last_error(e);
                -1
            }
        }
    })
}

/// # Safety
/// Arguments must be valid NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn cbo_input_search(
    field: *const c_char,
    query: *const c_char,
    limit: i32,
) -> *const c_char {
    guard(std::ptr::null(), || {
        match db::with(|c| {
            input_history::search(
                c,
                cstr(field).unwrap_or(""),
                cstr(query).unwrap_or(""),
                limit.max(0) as usize,
            )
        }) {
            Ok(rows) => ret_str(&serde_json::to_string(&rows).unwrap_or_else(|_| "[]".into())),
            Err(e) => {
                set_last_error(e);
                ret_str("[]")
            }
        }
    })
}

/// # Safety
/// `json` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn cbo_host_upsert(json: *const c_char) -> i32 {
    guard(-1, || {
        let Some(text) = cstr(json) else {
            set_last_error("json is required");
            return -1;
        };
        let r: Result<i64, String> = serde_json::from_str::<serde_json::Value>(text)
            .map_err(|e| format!("bad host json: {}", e))
            .and_then(|v| db::Host::from_json(&v))
            .and_then(|h| db::with(|c| db::host_upsert(c, &h)));
        match r {
            Ok(id) => id as i32,
            Err(e) => {
                set_last_error(e);
                -1
            }
        }
    })
}

#[no_mangle]
pub extern "C" fn cbo_host_delete(host_id: i32) -> i32 {
    guard(-1, || {
        match db::with(|c| db::host_delete(c, host_id as i64)) {
            Ok(true) => 0,
            Ok(false) => {
                set_last_error(format!("no host with id {}", host_id));
                -1
            }
            Err(e) => {
                set_last_error(e);
                -1
            }
        }
    })
}

#[no_mangle]
pub extern "C" fn cbo_host_get(host_id: i32) -> *const c_char {
    guard(std::ptr::null(), || {
        match db::with(|c| db::host_get(c, host_id as i64)) {
            Ok(Some(h)) => ret_str(&h.to_json().to_string()),
            Ok(None) => ret_str(""),
            Err(e) => {
                set_last_error(e);
                ret_str("")
            }
        }
    })
}

#[no_mangle]
pub extern "C" fn cbo_host_list() -> *const c_char {
    guard(std::ptr::null(), || {
        ret_json(
            db::with(db::host_list)
                .map(|l| serde_json::Value::Array(l.iter().map(db::Host::to_json).collect())),
            "[]",
        )
    })
}

#[no_mangle]
pub extern "C" fn cbo_session_set_host(id: i32, host_id: i32) -> i32 {
    guard(-1, || match session::get(id) {
        Some(s) => match record::set_host(&s, host_id as i64) {
            Ok(()) => 0,
            Err(e) => {
                set_last_error(e);
                -1
            }
        },
        None => {
            set_last_error(format!("bad session id {}", id));
            -1
        }
    })
}

// ---- recording --------------------------------------------------------

#[no_mangle]
pub extern "C" fn cbo_record_enable(on: i32) {
    guard((), || record::set_enabled(on != 0));
}

#[no_mangle]
pub extern "C" fn cbo_record_enabled() -> i32 {
    guard(0, || record::enabled() as i32)
}

/// # Safety
/// every pointer must be NULL or a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn cbo_record_event(
    kind: *const c_char,
    scene: *const c_char,
    action: *const c_char,
    data_json: *const c_char,
) -> i64 {
    guard(-1, || {
        let Some(kind) = cstr(kind) else {
            set_last_error("kind is required");
            return -1;
        };
        match record::event(
            kind,
            cstr(scene).unwrap_or(""),
            cstr(action).unwrap_or(""),
            cstr(data_json).unwrap_or(""),
        ) {
            Ok(id) => id,
            Err(e) => {
                set_last_error(e);
                -1
            }
        }
    })
}

#[no_mangle]
pub extern "C" fn cbo_session_transcript(id: i32, max_bytes: i32) -> *const c_char {
    guard(std::ptr::null(), || {
        let max = if max_bytes <= 0 {
            8192
        } else {
            max_bytes as usize
        };
        let Some(db_id) = context::resolve_session_db_id(id) else {
            return ret_str("");
        };
        let _ = record::flush_now();
        match db::with(|c| record::transcript(c, db_id, max)) {
            Ok(t) => ret_str(&t),
            Err(e) => {
                set_last_error(e);
                ret_str("")
            }
        }
    })
}

#[no_mangle]
pub extern "C" fn cbo_recent_commands(host_id: i32, limit: i32) -> *const c_char {
    guard(std::ptr::null(), || {
        let limit = if limit <= 0 {
            20
        } else {
            (limit as usize).min(1000)
        };
        let _ = record::flush_now();
        ret_json(
            db::with(|c| record::recent_commands(c, host_id as i64, limit))
                .map(serde_json::Value::Array),
            "[]",
        )
    })
}

// ---- search -----------------------------------------------------------

unsafe fn search_args(
    query: *const c_char,
    kinds_csv: *const c_char,
    limit: i32,
) -> (String, Vec<&'static str>, usize) {
    (
        cstr(query).unwrap_or("").to_string(),
        search::parse_kinds(cstr(kinds_csv).unwrap_or("")),
        if limit <= 0 {
            20
        } else {
            (limit as usize).min(1000)
        },
    )
}

/// # Safety
/// `query` and `kinds_csv` must be NULL or valid NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn cbo_search(
    query: *const c_char,
    kinds_csv: *const c_char,
    limit: i32,
) -> *const c_char {
    guard(std::ptr::null(), || {
        let (q, kinds, limit) = search_args(query, kinds_csv, limit);
        let _ = record::flush_now();
        ret_json(
            search::hybrid_global(&q, &kinds, limit).map(|h| search::to_json(&h)),
            "[]",
        )
    })
}

/// # Safety
/// `query` and `kinds_csv` must be NULL or valid NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn cbo_search_bm25(
    query: *const c_char,
    kinds_csv: *const c_char,
    limit: i32,
) -> *const c_char {
    guard(std::ptr::null(), || {
        let (q, kinds, limit) = search_args(query, kinds_csv, limit);
        let _ = record::flush_now();
        ret_json(
            db::with(|c| search::bm25(c, &q, &kinds, limit)).map(|h| search::to_json(&h)),
            "[]",
        )
    })
}

/// # Safety
/// `query` and `kinds_csv` must be NULL or valid NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn cbo_search_semantic(
    query: *const c_char,
    kinds_csv: *const c_char,
    limit: i32,
) -> *const c_char {
    guard(std::ptr::null(), || {
        let (q, kinds, limit) = search_args(query, kinds_csv, limit);
        ret_json(
            search::semantic_global(&q, &kinds, limit).map(|h| search::to_json(&h)),
            "[]",
        )
    })
}

#[no_mangle]
pub extern "C" fn cbo_embed_pending() -> i32 {
    guard(0, || {
        db::with(|c| Ok(embed::pending_count(c))).unwrap_or(0) as i32
    })
}

#[no_mangle]
pub extern "C" fn cbo_embed_available() -> i32 {
    guard(0, || embed::available() as i32)
}

// ---- patterns / context ----------------------------------------------

/// # Safety
/// `scene` and `last_action` must be NULL or valid NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn cbo_suggest(
    scene: *const c_char,
    last_action: *const c_char,
    limit: i32,
) -> *const c_char {
    guard(std::ptr::null(), || {
        let scene = cstr(scene).unwrap_or("").to_string();
        let last = cstr(last_action).unwrap_or("").to_string();
        let limit = if limit <= 0 { 5 } else { limit as usize };
        let bucket = patterns::hour_bucket(session::now_ms() as i64);
        ret_json(
            db::with(|c| patterns::suggest(c, &scene, &last, bucket, limit))
                .map(serde_json::Value::Array),
            "[]",
        )
    })
}

/// # Safety
/// `scene` must be NULL or a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn cbo_context(
    scene: *const c_char,
    session_id: i32,
    max_chars: i32,
) -> *const c_char {
    guard(std::ptr::null(), || {
        let scene = cstr(scene).unwrap_or("").to_string();
        let max = if max_chars <= 0 {
            4000
        } else {
            max_chars as usize
        };
        let _ = record::flush_now();
        ret_json(
            db::with(|c| context::context(c, &scene, session_id, max)),
            "{}",
        )
    })
}

#[no_mangle]
pub extern "C" fn cbo_stats() -> *const c_char {
    guard(std::ptr::null(), || {
        let _ = record::flush_now();
        ret_json(db::with(context::stats), "{}")
    })
}

// ---- typing assist ----------------------------------------------------

#[no_mangle]
pub extern "C" fn cbo_session_typing(id: i32) -> *const c_char {
    guard(std::ptr::null(), || match session::get(id) {
        Some(s) => ret_str(&session::lock(&s.learning).typing()),
        None => ret_str(""),
    })
}

#[no_mangle]
pub extern "C" fn cbo_session_can_complete(id: i32) -> i32 {
    guard(0, || {
        let Some(s) = session::get(id) else {
            return 0;
        };
        if s.state() != session::ST_CONNECTED {
            return 0;
        }
        let line = session::lock(&s.term).prompt_line();
        let ready = session::lock(&s.learning).ready(line.as_deref());
        ready as i32
    })
}

/// # Safety
/// `prefix` must be NULL or a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn cbo_complete(
    host_id: i32,
    prefix: *const c_char,
    limit: i32,
) -> *const c_char {
    guard(std::ptr::null(), || {
        let prefix = cstr(prefix).unwrap_or("").to_string();
        let limit = assist::clamp_limit(limit);
        ret_json(
            db::with(|c| assist::complete(c, host_id as i64, &prefix, limit))
                .map(|l| assist::to_json(&l)),
            "[]",
        )
    })
}

#[no_mangle]
pub extern "C" fn cbo_predict_next(host_id: i32, limit: i32) -> *const c_char {
    guard(std::ptr::null(), || {
        let limit = assist::clamp_limit(limit);
        ret_json(
            db::with(|c| assist::predict_next(c, host_id as i64, limit))
                .map(|l| assist::to_json(&l)),
            "[]",
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utf8_width_mixed_scripts() {
        let s = CString::new("你好 안녕 こんにちは Příliš").unwrap_or_default();
        // 你好=4, ' '=1, 안녕=4, ' '=1, こんにちは=10, ' '=1, Příliš=6 => 27
        assert_eq!(unsafe { cbo_utf8_width(s.as_ptr()) }, 27);
        assert_eq!(unsafe { cbo_utf8_width(std::ptr::null()) }, 0);
    }

    #[test]
    fn version_and_errors_round_trip() {
        let v = unsafe { CStr::from_ptr(cbo_version()) }
            .to_str()
            .unwrap_or("");
        assert_eq!(v, VERSION);
        let e = unsafe { CStr::from_ptr(cbo_last_error()) }
            .to_str()
            .unwrap_or("x");
        assert_eq!(e, "");
        let bad = unsafe {
            cbo_session_open(
                std::ptr::null(),
                22,
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                80,
                24,
            )
        };
        assert_eq!(bad, -1);
        let e = unsafe { CStr::from_ptr(cbo_last_error()) }
            .to_str()
            .unwrap_or("");
        assert!(e.contains("host"));
    }

    #[test]
    fn name_generate_is_c_string() {
        let p = cbo_name_generate(99);
        let n = unsafe { CStr::from_ptr(p) }.to_str().unwrap_or("");
        assert!(n.contains('-'));
    }
}
