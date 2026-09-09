//! Session names and fuzzy search: public Rust API plus the FFI entry points
//! against a live (CONNECTING) session.

mod common;

use std::time::Duration;

use cbo_core::fuzzy::{search, Candidate};
use cbo_core::names::{generate, ADJECTIVES, NOUNS};
use cbo_core::*;
use common::*;

fn parse(name: &str) -> Option<(&str, &str, u32)> {
    let (rest, nn) = name.rsplit_once('-')?;
    let nn: u32 = nn.parse().ok()?;
    let adj = ADJECTIVES
        .iter()
        .find(|a| rest.starts_with(&format!("{}-", a)))?;
    let noun = &rest[adj.len() + 1..];
    NOUNS.contains(&noun).then_some((*adj, noun, nn))
}

#[test]
fn format_is_adjective_hk_noun_two_digits() {
    for seed in 1..=500u64 {
        let n = generate(seed, &[]);
        let (_, _, nn) = parse(&n).unwrap_or_else(|| panic!("bad name {:?}", n));
        assert!(nn < 100);
        assert!(n.len() <= 32 && n.is_ascii(), "{:?}", n);
        assert_eq!(n.rsplit_once('-').map(|(_, d)| d.len()), Some(2), "{:?}", n);
    }
}

#[test]
fn seeded_names_are_deterministic_and_spread() {
    assert_eq!(generate(99, &[]), generate(99, &[]));
    let distinct: std::collections::HashSet<String> =
        (1..=500u64).map(|s| generate(s, &[])).collect();
    assert!(
        distinct.len() > 450,
        "only {} distinct names for 500 seeds",
        distinct.len()
    );
}

#[test]
fn unique_against_taken_names() {
    let mut taken: Vec<String> = Vec::new();
    for seed in 1..=300u64 {
        let n = generate(seed, &taken);
        assert!(!taken.contains(&n), "collision on {:?}", n);
        taken.push(n);
    }
    let first = generate(5, &[]);
    assert_ne!(generate(5, std::slice::from_ref(&first)), first);
}

fn c(id: i32, name: &str, host: &str, user: &str, act: u64) -> Candidate {
    Candidate {
        id,
        name: name.into(),
        host: host.into(),
        user: user.into(),
        port: 22,
        last_activity_ms: act,
    }
}

fn fixture() -> Vec<Candidate> {
    vec![
        c(0, "neon-tram-07", "box.example.com", "root", 10),
        c(1, "tram-jade-11", "10.0.0.5", "alice", 50),
        c(2, "misty-peak-02", "tramway.hk", "bob", 30),
        c(3, "golden-junk-09", "server", "carol", 40),
        c(4, "香港-辦公室", "hk.example.com", "dev", 20),
        c(5, "안녕-ferry-01", "seoul", "kim", 60),
    ]
}

#[test]
fn multi_word_query_regression() {
    let cs = fixture();
    assert_eq!(
        search("neon tr", &cs),
        vec![0],
        "'neon tr' must find neon-tram-07"
    );
    assert_eq!(search("tram alice", &cs), vec![1]);
    assert_eq!(search("  neon   tram ", &cs), vec![0]);
    assert!(search("neon zzz", &cs).is_empty(), "every term must match");
}

#[test]
fn ranking_name_prefix_then_name_word_then_host() {
    assert_eq!(search("tram", &fixture()), vec![1, 0, 2]);
}

#[test]
fn cjk_queries() {
    let cs = fixture();
    assert_eq!(search("香港", &cs), vec![4]);
    assert_eq!(search("辦公室", &cs), vec![4]);
    assert_eq!(search("안녕", &cs), vec![5]);
    assert_eq!(search("안녕 ferry", &cs), vec![5]);
    assert!(search("東京", &cs).is_empty());
}

#[test]
fn empty_query_orders_by_last_activity_desc() {
    let cs = fixture();
    assert_eq!(search("", &cs), vec![5, 1, 3, 2, 4, 0]);
    assert_eq!(search("   \t", &cs), vec![5, 1, 3, 2, 4, 0]);
}

#[test]
fn host_user_and_port_fields() {
    let cs = fixture();
    assert_eq!(search("10.0.0.5:22", &cs), vec![1]);
    assert_eq!(search("alice@10", &cs), vec![1]);
    assert_eq!(search("CAROL", &cs), vec![3]);
    assert!(search("zzzz", &cs).is_empty());
}

/// FFI path with a live session: `cbo_name_generate` must avoid live names
/// and `cbo_session_search` must see the session's name / host / user.
#[test]
fn ffi_name_generate_avoids_live_names_and_search_sees_sessions() {
    let _g = serial();
    cbo_init();
    let id = open(BLACKHOLE, 22, "alice", None, None, 80, 24);
    assert!(id >= 0, "{}", last_error());

    let seeded = generate(4242, &[]);
    let also = from_c(cbo_name_generate(4242));
    assert_eq!(also, seeded, "seed honoured when the name is free");
    let n = cs(&seeded);
    assert_eq!(unsafe { cbo_session_set_name(id, n.as_ptr()) }, 0);
    assert_eq!(from_c(cbo_session_get_name(id)), seeded);
    let fresh = from_c(cbo_name_generate(4242));
    assert_ne!(fresh, seeded, "live name must be avoided");
    assert!(parse(&fresh).is_some(), "{:?}", fresh);

    let mut out = [-1i32; 4];
    let q = cs("alice");
    assert_eq!(
        unsafe { cbo_session_search(q.as_ptr(), out.as_mut_ptr(), 4) },
        1
    );
    assert_eq!(out[0], id);
    let q = cs(&seeded[..4]);
    assert_eq!(
        unsafe { cbo_session_search(q.as_ptr(), out.as_mut_ptr(), 4) },
        1
    );
    let q = cs("10.255");
    assert_eq!(
        unsafe { cbo_session_search(q.as_ptr(), out.as_mut_ptr(), 4) },
        1
    );
    let q = cs("");
    assert_eq!(
        unsafe { cbo_session_search(q.as_ptr(), out.as_mut_ptr(), 4) },
        1
    );
    let q = cs("nomatch-xyz");
    assert_eq!(
        unsafe { cbo_session_search(q.as_ptr(), out.as_mut_ptr(), 4) },
        0
    );

    // Rename rules: <= 32 chars, non-empty, any UTF-8.
    let hk = cs("香港-辦公室");
    assert_eq!(unsafe { cbo_session_set_name(id, hk.as_ptr()) }, 0);
    let long = cs(&"x".repeat(33));
    assert_eq!(unsafe { cbo_session_set_name(id, long.as_ptr()) }, -1);
    assert!(last_error().contains("32"));
    let ok = cs(&"x".repeat(32));
    assert_eq!(unsafe { cbo_session_set_name(id, ok.as_ptr()) }, 0);
    let blank = cs("   ");
    assert_eq!(unsafe { cbo_session_set_name(id, blank.as_ptr()) }, -1);

    cbo_session_close(id);
    let t = std::time::Instant::now();
    while !matches!(cbo_session_state(id), ST_CLOSED | ST_ERROR)
        && t.elapsed() < Duration::from_secs(5)
    {
        std::thread::sleep(Duration::from_millis(10));
    }
    cbo_session_free(id);
    assert_eq!(cbo_session_count(), 0);
}
