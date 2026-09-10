//! C ABI contract: struct layouts as declared in include/cbo.h, NULL / bad-id
//! safety on every extern fn, thread-local string buffer semantics.

mod common;

use std::mem::{align_of, offset_of, size_of};

use cbo_core::*;
use common::*;

// ------------------------------------------------------------ layouts

const _: () = assert!(size_of::<CboCell>() == 16);
const _: () = assert!(align_of::<CboCell>() == 4);
const _: () = assert!(offset_of!(CboCell, cp) == 0);
const _: () = assert!(offset_of!(CboCell, fg) == 4);
const _: () = assert!(offset_of!(CboCell, bg) == 8);
const _: () = assert!(offset_of!(CboCell, attr) == 12);
const _: () = assert!(offset_of!(CboCell, width) == 13);
const _: () = assert!(offset_of!(CboCell, _pad) == 14);

const _: () = assert!(size_of::<CboSessionInfo>() == 304);
const _: () = assert!(align_of::<CboSessionInfo>() == 8);
const _: () = assert!(offset_of!(CboSessionInfo, id) == 0);
const _: () = assert!(offset_of!(CboSessionInfo, state) == 4);
const _: () = assert!(offset_of!(CboSessionInfo, cols) == 8);
const _: () = assert!(offset_of!(CboSessionInfo, rows) == 10);
const _: () = assert!(offset_of!(CboSessionInfo, port) == 12);
const _: () = assert!(offset_of!(CboSessionInfo, _pad) == 14);
const _: () = assert!(offset_of!(CboSessionInfo, created_ms) == 16);
const _: () = assert!(offset_of!(CboSessionInfo, last_activity_ms) == 24);
const _: () = assert!(offset_of!(CboSessionInfo, last_ping_ms) == 32);
const _: () = assert!(offset_of!(CboSessionInfo, generation) == 40);
const _: () = assert!(offset_of!(CboSessionInfo, name) == 48);
const _: () = assert!(offset_of!(CboSessionInfo, host) == 112);
const _: () = assert!(offset_of!(CboSessionInfo, user) == 240);

#[test]
fn struct_layouts_match_header() {
    // The const asserts above are the test; this keeps them from being
    // optimised out of the report and checks the enum values the header fixes.
    assert_eq!(size_of::<CboCell>(), 16);
    assert_eq!(size_of::<CboSessionInfo>(), 304);
    assert_eq!(
        (ST_IDLE, ST_CONNECTING, ST_CONNECTED, ST_CLOSED, ST_ERROR),
        (0, 1, 2, 3, 4)
    );
    assert_eq!(
        (LLM_PENDING, LLM_STREAMING, LLM_DONE, LLM_ERROR),
        (0, 1, 2, 3)
    );
    assert_eq!(
        (
            cbo_core::term::ATTR_BOLD,
            cbo_core::term::ATTR_ITALIC,
            cbo_core::term::ATTR_UNDERLINE,
            cbo_core::term::ATTR_INVERSE,
            cbo_core::term::ATTR_BLINK,
            cbo_core::term::ATTR_DIM
        ),
        (1, 2, 4, 8, 16, 32)
    );
    assert_eq!(cbo_core::session::MAX_SESSIONS, 128);
}

#[test]
fn info_strings_are_nul_terminated_and_utf8_safe() {
    let _g = serial();
    let id = open(BLACKHOLE, 2222, "someone", None, None, 100, 30);
    assert!(id >= 0, "{}", last_error());
    let n = cs("香港-辦公室");
    assert_eq!(unsafe { cbo_session_set_name(id, n.as_ptr()) }, 0);
    let i = info(id);
    assert_eq!(i.id, id);
    assert_eq!((i.cols, i.rows, i.port), (100, 30, 2222));
    assert_eq!(i._pad, 0);
    assert!(i.created_ms > 1_700_000_000_000);
    assert!(i.last_activity_ms >= i.created_ms);
    assert_eq!(i.last_ping_ms, 0);
    let name = std::ffi::CStr::from_bytes_until_nul(&i.name).expect("nul");
    assert_eq!(name.to_str().expect("utf8"), "香港-辦公室");
    let host = std::ffi::CStr::from_bytes_until_nul(&i.host).expect("nul");
    assert_eq!(host.to_str().expect("utf8"), BLACKHOLE);
    let user = std::ffi::CStr::from_bytes_until_nul(&i.user).expect("nul");
    assert_eq!(user.to_str().expect("utf8"), "someone");
    cbo_session_close(id);
    let t = std::time::Instant::now();
    while !matches!(cbo_session_state(id), ST_CLOSED | ST_ERROR) && t.elapsed().as_secs() < 5 {
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    cbo_session_free(id);
    assert_eq!(cbo_session_count(), 0);
}

// ------------------------------------------------------- NULL / bad ids

#[test]
fn every_entry_point_survives_nulls_and_bad_ids() {
    let _g = serial();
    cbo_init();
    let null: *const std::ffi::c_char = std::ptr::null();
    for id in [-1, 128, 999, i32::MIN, i32::MAX] {
        assert_eq!(cbo_session_state(id), ST_IDLE);
        assert_eq!(from_c(cbo_session_error(id)), "");
        assert_eq!(unsafe { cbo_session_info(id, std::ptr::null_mut()) }, -1);
        let mut out = unsafe { std::mem::zeroed::<CboSessionInfo>() };
        assert_eq!(unsafe { cbo_session_info(id, &mut out) }, -1);
        unsafe { cbo_session_write(id, b"x".as_ptr(), 1) };
        unsafe { cbo_session_write(id, std::ptr::null(), 5) };
        cbo_session_resize(id, 0, 0);
        cbo_session_close(id);
        cbo_session_free(id);
        assert!(!last_error().is_empty());
        assert_eq!(unsafe { cbo_session_set_name(id, null) }, -1);
        let n = cs("x");
        assert_eq!(unsafe { cbo_session_set_name(id, n.as_ptr()) }, -1);
        assert_eq!(from_c(cbo_session_get_name(id)), "");
        cbo_session_set_keepalive(id, 5);
        assert_eq!(cbo_session_reconnect(id), -1);
        assert_eq!(
            unsafe { cbo_term_snapshot(id, std::ptr::null_mut(), 10) },
            0
        );
        let mut cells = [CboCell::default(); 4];
        assert_eq!(unsafe { cbo_term_snapshot(id, cells.as_mut_ptr(), 4) }, 0);
        assert_eq!(unsafe { cbo_term_snapshot(id, cells.as_mut_ptr(), 0) }, 0);
        assert_eq!(unsafe { cbo_term_snapshot(id, cells.as_mut_ptr(), -1) }, 0);
        assert_eq!(cbo_term_generation(id), 0);
        unsafe {
            cbo_term_cursor(
                id,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert_eq!(cursor(id), (0, 0, 0));
        assert_eq!(from_c(cbo_term_title(id)), "");
        assert_eq!(cbo_term_take_bell(id), 0);
        cbo_term_scroll(id, 5);
        assert_eq!(cbo_term_scroll_offset(id), 0);
        assert_eq!(cbo_term_scrollback_len(id), 0);
        assert_eq!(cbo_llm_state(id), LLM_ERROR);
        assert_eq!(from_c(cbo_llm_take_delta(id)), "");
        assert!(!from_c(cbo_llm_error(id)).is_empty());
        cbo_llm_cancel(id);
        cbo_llm_free(id);
    }

    // NULL strings on the constructors.
    assert_eq!(
        unsafe { cbo_session_open(null, 22, null, null, null, 80, 24) },
        -1
    );
    assert!(last_error().contains("host"));
    let h = cs("localhost");
    assert_eq!(
        unsafe { cbo_session_open(h.as_ptr(), 22, null, null, null, 80, 24) },
        -1
    );
    assert!(last_error().contains("user"));
    let blank = cs("   ");
    assert_eq!(
        unsafe { cbo_session_open(blank.as_ptr(), 22, h.as_ptr(), null, null, 80, 24) },
        -1
    );
    assert_eq!(unsafe { cbo_llm_start(null, null, null, null, null) }, -1);
    assert!(last_error().contains("provider"));
    let p = cs("openai");
    assert_eq!(
        unsafe { cbo_llm_start(p.as_ptr(), null, null, null, null) },
        -1
    );
    let m = cs("[]");
    assert_eq!(
        unsafe { cbo_llm_start(p.as_ptr(), null, null, null, m.as_ptr()) },
        -1
    );
    assert!(last_error().contains("API key"), "{}", last_error());
    let k = cs("k");
    let bad = cs("{not json");
    assert_eq!(
        unsafe { cbo_llm_start(p.as_ptr(), k.as_ptr(), null, null, bad.as_ptr()) },
        -1
    );
    assert!(last_error().contains("JSON"), "{}", last_error());

    assert_eq!(unsafe { cbo_utf8_width(null) }, 0);
    assert_eq!(unsafe { cbo_session_ids(std::ptr::null_mut(), 10) }, 0);
    let mut ids = [0i32; 2];
    assert_eq!(unsafe { cbo_session_ids(ids.as_mut_ptr(), 0) }, 0);
    assert_eq!(
        unsafe { cbo_session_search(null, std::ptr::null_mut(), 0) },
        0
    );
    let q = cs("x");
    assert_eq!(
        unsafe { cbo_session_search(q.as_ptr(), ids.as_mut_ptr(), -1) },
        0
    );
    assert_eq!(cbo_session_count(), 0);
    assert!(cbo_now_ms() > 1_700_000_000_000);
    assert!(!from_c(cbo_last_error()).contains("internal panic"));
}

#[test]
fn ids_and_search_respect_cap() {
    let _g = serial();
    let a = open(BLACKHOLE, 22, "u", None, None, 80, 24);
    let b = open(BLACKHOLE, 22, "u", None, None, 80, 24);
    let c = open(BLACKHOLE, 22, "u", None, None, 80, 24);
    assert!(a >= 0 && b >= 0 && c >= 0);
    assert_eq!(cbo_session_count(), 3);
    let mut ids = [-1i32; 2];
    assert_eq!(
        unsafe { cbo_session_ids(ids.as_mut_ptr(), 2) },
        2,
        "cap honoured"
    );
    assert_eq!(
        unsafe { cbo_session_ids(std::ptr::null_mut(), 0) },
        3,
        "NULL out reports the count"
    );
    let q = cs("");
    assert_eq!(
        unsafe { cbo_session_search(q.as_ptr(), ids.as_mut_ptr(), 2) },
        2
    );
    assert_eq!(
        unsafe { cbo_session_search(q.as_ptr(), std::ptr::null_mut(), 0) },
        3
    );
    for id in [a, b, c] {
        cbo_session_close(id);
    }
    let t = std::time::Instant::now();
    for id in [a, b, c] {
        while !matches!(cbo_session_state(id), ST_CLOSED | ST_ERROR) && t.elapsed().as_secs() < 5 {
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        cbo_session_free(id);
    }
    assert_eq!(cbo_session_count(), 0);
}

// -------------------------------------------- thread-local string buffer

#[test]
fn returned_strings_live_until_the_next_call_on_the_same_thread() {
    let p1 = cbo_version();
    let s1 = from_c(p1);
    assert_eq!(s1, VERSION);
    // The pointer is still valid before any other call.
    assert_eq!(from_c(p1), VERSION);
    let p2 = cbo_name_generate(77);
    let s2 = from_c(p2);
    assert!(s2.contains('-'));
    // Reading p1 now is undefined per the contract; we only require that the
    // copy taken earlier is intact and the fresh pointer is right.
    assert_eq!(s1, VERSION);
    assert_eq!(from_c(p2), s2);
    // An empty string is a valid, non-NULL "" pointer.
    let e = cbo_last_error_after_clear();
    assert!(!e.is_null());
    assert_eq!(from_c(e), "");
}

fn cbo_last_error_after_clear() -> *const std::ffi::c_char {
    cbo_init();
    cbo_last_error()
}

#[test]
fn string_buffers_are_per_thread() {
    let handles: Vec<_> = (0..8u64)
        .map(|i| {
            std::thread::spawn(move || {
                for _ in 0..200 {
                    let want = cbo_core::names::generate(i + 1, &[]);
                    let got = from_c(cbo_name_generate(i + 1));
                    assert_eq!(got, want, "thread {} saw another thread's buffer", i);
                    let bad = cs("");
                    let _ = unsafe {
                        cbo_session_open(
                            bad.as_ptr(),
                            22,
                            bad.as_ptr(),
                            std::ptr::null(),
                            std::ptr::null(),
                            1,
                            1,
                        )
                    };
                    assert_eq!(from_c(cbo_last_error()), "host is required");
                }
            })
        })
        .collect();
    for h in handles {
        h.join().expect("thread");
    }
}

#[test]
fn utf8_width_matches_matrix() {
    for case in MATRIX {
        assert_eq!(utf8_width(case.text), case.cols as i32, "[{}]", case.label);
    }
    assert_eq!(utf8_width(""), 0);
    assert_eq!(utf8_width("你好 안녕 こんにちは Příliš"), 27);
}

#[test]
fn note_entry_points_survive_bad_input() {
    cbo_init();
    let null: *const std::ffi::c_char = std::ptr::null();
    assert_eq!(unsafe { cbo_note_add(null, 0) }, -1);
    assert!(!from_c(cbo_last_error()).is_empty());
    assert_eq!(cbo_note_delete(-5), -1);
    assert_eq!(cbo_note_delete(i64::MAX), -1);
    let list = from_c(cbo_note_list(-1));
    assert!(list.starts_with('['), "{}", list);
    let list = from_c(cbo_note_list(i32::MAX));
    assert!(list.starts_with('['), "{}", list);
    let huge = cs(&"x".repeat(cbo_core::notes::MAX_CHARS + 1));
    assert_eq!(unsafe { cbo_note_add(huge.as_ptr(), 0) }, -1);
    assert!(from_c(cbo_last_error()).contains("longer"));
}
