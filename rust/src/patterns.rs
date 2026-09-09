//! Learned UI patterns: (scene, prev_action) -> action transition counts per
//! 3-hour bucket, used to rank "what the user usually does next".

use std::collections::HashMap;
use std::sync::Mutex;

use rusqlite::{params, Connection};
use serde_json::{json, Value};

use crate::db;
use crate::session::lock;

/// Boost for transitions seen in the same time-of-day bucket.
pub const SAME_BUCKET_BOOST: f64 = 1.5;
pub const BUCKET_HOURS: i64 = 3;

/// Last action seen per scene (in-memory, resets with the process).
static LAST: Mutex<Option<HashMap<String, String>>> = Mutex::new(None);

/// Local hour / 3 for a unix-ms timestamp.
pub fn hour_bucket(ts_ms: i64) -> i64 {
    let secs = (ts_ms / 1000) as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: localtime_r writes into the tm we own; secs is a plain value.
    let ok = unsafe { !libc::localtime_r(&secs, &mut tm).is_null() };
    let hour = if ok {
        tm.tm_hour as i64
    } else {
        ((ts_ms / 3_600_000) % 24 + 24) % 24
    };
    hour / BUCKET_HOURS
}

/// Record a ui/nav event. Returns the previous action it was chained to.
pub fn observe(
    conn: &Connection,
    kind: &str,
    scene: &str,
    action: &str,
    ts_ms: i64,
) -> Result<String, String> {
    let scene = scene.trim();
    let action = action.trim();
    if scene.is_empty() || action.is_empty() {
        return Ok(String::new());
    }
    let prev = {
        let mut g = lock(&LAST);
        let map = g.get_or_insert_with(HashMap::new);
        let prev = map.get(scene).cloned().unwrap_or_default();
        if kind == "nav" {
            // Leaving for another scene: the next action there starts fresh.
            map.retain(|s, _| s == scene);
        }
        map.insert(scene.to_string(), action.to_string());
        prev
    };
    record_transition(conn, scene, &prev, action, hour_bucket(ts_ms))?;
    Ok(prev)
}

pub fn record_transition(
    conn: &Connection,
    scene: &str,
    prev: &str,
    action: &str,
    bucket: i64,
) -> Result<(), String> {
    conn.execute(
        "INSERT INTO transitions(scene, prev_action, action, hour_bucket, count) VALUES (?1,?2,?3,?4,1)
         ON CONFLICT(scene, prev_action, action, hour_bucket) DO UPDATE SET count = count + 1",
        params![scene, prev, action, bucket],
    )
    .map(|_| ())
    .map_err(db::sql_err)
}

/// Forget the in-memory chain (tests / scene reset).
pub fn reset_chain() {
    *lock(&LAST) = None;
}

/// [{action, count, prob}] ranked by time-weighted count.
pub fn suggest(
    conn: &Connection,
    scene: &str,
    last_action: &str,
    now_bucket: i64,
    limit: usize,
) -> Result<Vec<Value>, String> {
    let mut st = conn
        .prepare("SELECT action, hour_bucket, count FROM transitions WHERE scene = ?1 AND prev_action = ?2")
        .map_err(db::sql_err)?;
    let rows = st
        .query_map(params![scene.trim(), last_action.trim()], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, i64>(2)?,
            ))
        })
        .map_err(db::sql_err)?;
    let mut agg: HashMap<String, (i64, f64)> = HashMap::new();
    for row in rows {
        let (action, bucket, count) = row.map_err(db::sql_err)?;
        let w = if bucket == now_bucket {
            SAME_BUCKET_BOOST
        } else {
            1.0
        };
        let e = agg.entry(action).or_insert((0, 0.0));
        e.0 += count;
        e.1 += count as f64 * w;
    }
    let total: f64 = agg.values().map(|v| v.1).sum();
    let mut list: Vec<(String, i64, f64)> = agg.into_iter().map(|(a, (c, w))| (a, c, w)).collect();
    list.sort_by(|a, b| {
        b.2.partial_cmp(&a.2)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.0.cmp(&b.0))
    });
    Ok(list
        .into_iter()
        .take(limit.max(1))
        .map(|(action, count, w)| {
            let prob = if total > 0.0 { w / total } else { 0.0 };
            json!({"action": action, "count": count, "prob": (prob * 1000.0).round() / 1000.0})
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transitions_count_and_suggest_orders_by_count() {
        let conn = db::open_memory().expect("db");
        reset_chain();
        let t = 1_700_000_000_000;
        // lobby: entry -> connect (3x), entry -> search (1x)
        for _ in 0..3 {
            observe(&conn, "nav", "lobby", "connect", t).expect("obs");
            observe(&conn, "nav", "terminal", "back", t).expect("obs");
            observe(&conn, "nav", "lobby", "connect", t).expect("obs");
            reset_chain();
        }
        observe(&conn, "ui", "lobby", "search", t).expect("obs");
        reset_chain();
        let s = suggest(&conn, "lobby", "", hour_bucket(t), 5).expect("suggest");
        assert_eq!(s[0]["action"], "connect");
        assert_eq!(s[0]["count"], 6);
        assert_eq!(s[1]["action"], "search");
        let p0 = s[0]["prob"].as_f64().unwrap_or(0.0);
        let p1 = s[1]["prob"].as_f64().unwrap_or(0.0);
        assert!(
            (p0 + p1 - 1.0).abs() < 0.01,
            "probs sum to 1: {} {}",
            p0,
            p1
        );
        // after "connect" in lobby nothing follows in lobby (nav went to terminal)
        assert!(suggest(&conn, "lobby", "connect", 0, 5)
            .expect("s")
            .is_empty());
        // the chain: terminal "back" is entry-level there
        let t2 = suggest(&conn, "terminal", "", 0, 5).expect("s");
        assert_eq!(t2[0]["action"], "back");
    }

    #[test]
    fn same_bucket_boost_reorders() {
        let conn = db::open_memory().expect("db");
        record_transition(&conn, "s", "", "a", 1).expect("t");
        record_transition(&conn, "s", "", "a", 1).expect("t");
        record_transition(&conn, "s", "", "a", 1).expect("t"); // a: 3 in bucket 1
        for _ in 0..2 {
            record_transition(&conn, "s", "", "b", 4).expect("t"); // b: 2 in bucket 4
        }
        let far = suggest(&conn, "s", "", 0, 5).expect("s");
        assert_eq!(far[0]["action"], "a");
        let near_b = suggest(&conn, "s", "", 4, 5).expect("s");
        // b: 2*1.5 = 3 == a: 3 -> tie broken alphabetically, a first
        assert_eq!(near_b[0]["action"], "a");
        record_transition(&conn, "s", "", "b", 4).expect("t"); // b: 3*1.5 = 4.5 > 3
        let near_b = suggest(&conn, "s", "", 4, 5).expect("s");
        assert_eq!(near_b[0]["action"], "b");
        assert_eq!(near_b[0]["count"], 3);
        assert_eq!(suggest(&conn, "s", "", 4, 1).expect("s").len(), 1);
    }

    #[test]
    fn hour_bucket_in_range() {
        for h in 0..24 {
            let b = hour_bucket(1_700_000_000_000 + h * 3_600_000);
            assert!((0..8).contains(&b));
        }
    }
}
