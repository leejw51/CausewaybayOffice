//! Typing assist: prefix completions and next-command prediction over the
//! recorded command history. Called on every keystroke, so queries use
//! cached prepared statements, scan a bounded window of recent commands and
//! aggregate in Rust.

use std::collections::HashMap;

use rusqlite::{params, Connection};
use serde_json::{json, Value};

use crate::db;
use crate::session::now_ms;

pub const MAX_LIMIT: usize = 20;
/// Recency half-life for frequency decay.
pub const HALF_LIFE_MS: f64 = 7.0 * 24.0 * 3600.0 * 1000.0;
pub const SAME_HOST_BOOST: f64 = 1.5;
/// Bonus for commands that also match the BM25 prefix query.
pub const FTS_BOOST: f64 = 1.2;
/// Weight of a transition count relative to decayed frequency.
pub const TRANSITION_WEIGHT: f64 = 2.0;
/// How many recent command rows feed the aggregation.
const WINDOW_ROWS: i64 = 2000;

#[derive(Clone, Debug, PartialEq)]
pub struct Candidate {
    pub cmd: String,
    pub score: f64,
    pub source: &'static str,
    pub count: i64,
    pub last_ms: i64,
}

impl Candidate {
    pub fn to_json(&self) -> Value {
        json!({
            "cmd": self.cmd,
            "score": (self.score * 1000.0).round() / 1000.0,
            "source": self.source,
            "count": self.count,
            "last_ms": self.last_ms,
        })
    }
}

pub fn to_json(list: &[Candidate]) -> Value {
    Value::Array(list.iter().map(Candidate::to_json).collect())
}

pub fn clamp_limit(limit: i32) -> usize {
    if limit <= 0 {
        10
    } else {
        (limit as usize).min(MAX_LIMIT)
    }
}

/// 0.5 ^ (age / half-life).
pub fn decay(ts_ms: i64, now: i64) -> f64 {
    let age = (now - ts_ms).max(0) as f64;
    (0.5f64).powf(age / HALF_LIFE_MS)
}

#[derive(Default)]
struct Agg {
    count: i64,
    last_ms: i64,
    freq: f64,
    on_host: bool,
}

/// Aggregate recent occurrences per command. `filter` is an optional
/// case-insensitive prefix (applied in SQL).
fn aggregate(
    conn: &Connection,
    host_id: i64,
    prefix: Option<&str>,
    now: i64,
) -> Result<HashMap<String, Agg>, String> {
    let mut agg: HashMap<String, Agg> = HashMap::new();
    let mut fold = |cmd: String, ts: i64, hid: i64| {
        let e = agg.entry(cmd).or_default();
        e.count += 1;
        e.last_ms = e.last_ms.max(ts);
        e.freq += decay(ts, now);
        if host_id > 0 && hid == host_id {
            e.on_host = true;
        }
    };
    match prefix.filter(|p| !p.is_empty()) {
        Some(p) => {
            let mut st = conn
                .prepare_cached(
                    "SELECT cmd, ts_ms, host_id FROM commands
                     WHERE lower(substr(cmd, 1, ?2)) = lower(?1)
                     ORDER BY id DESC LIMIT ?3",
                )
                .map_err(db::sql_err)?;
            let rows = st
                .query_map(params![p, p.chars().count() as i64, WINDOW_ROWS], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, i64>(1)?,
                        r.get::<_, i64>(2)?,
                    ))
                })
                .map_err(db::sql_err)?;
            for row in rows {
                let (c, t, h) = row.map_err(db::sql_err)?;
                fold(c, t, h);
            }
        }
        None => {
            let mut st = conn
                .prepare_cached(
                    "SELECT cmd, ts_ms, host_id FROM commands ORDER BY id DESC LIMIT ?1",
                )
                .map_err(db::sql_err)?;
            let rows = st
                .query_map(params![WINDOW_ROWS], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, i64>(1)?,
                        r.get::<_, i64>(2)?,
                    ))
                })
                .map_err(db::sql_err)?;
            for row in rows {
                let (c, t, h) = row.map_err(db::sql_err)?;
                fold(c, t, h);
            }
        }
    }
    Ok(agg)
}

/// Commands whose tokens BM25-prefix-match `prefix` (distinct cmd text).
fn fts_matches(conn: &Connection, prefix: &str) -> Result<Vec<String>, String> {
    let q = crate::search::fts_query(prefix);
    if q.is_empty() {
        return Ok(Vec::new());
    }
    let mut st = conn
        .prepare_cached(
            "SELECT DISTINCT c.cmd FROM commands_fts f JOIN commands c ON c.id = f.rowid
             WHERE commands_fts MATCH ?1 ORDER BY bm25(commands_fts) LIMIT 50",
        )
        .map_err(db::sql_err)?;
    let rows = st
        .query_map(params![q], |r| r.get::<_, String>(0))
        .map_err(db::sql_err)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(db::sql_err)
}

fn finish(mut list: Vec<Candidate>, limit: usize) -> Vec<Candidate> {
    list.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(b.last_ms.cmp(&a.last_ms))
            .then(a.cmd.cmp(&b.cmd))
    });
    list.truncate(limit);
    list
}

/// Completions for `prefix` ("" = most frequent commands).
pub fn complete(
    conn: &Connection,
    host_id: i64,
    prefix: &str,
    limit: usize,
) -> Result<Vec<Candidate>, String> {
    let now = now_ms() as i64;
    let prefix = prefix.trim_start();
    let mut agg = aggregate(conn, host_id, Some(prefix).filter(|p| !p.is_empty()), now)?;
    let mut fts_hit: HashMap<String, ()> = HashMap::new();
    if !prefix.is_empty() {
        for cmd in fts_matches(conn, prefix)? {
            fts_hit.insert(cmd.clone(), ());
            if !agg.contains_key(&cmd) {
                // Token match without a literal prefix: fetch its stats.
                let mut st = conn
                    .prepare_cached(
                        "SELECT ts_ms, host_id FROM commands WHERE cmd = ?1 ORDER BY id DESC LIMIT 200",
                    )
                    .map_err(db::sql_err)?;
                let rows = st
                    .query_map(params![cmd], |r| {
                        Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?))
                    })
                    .map_err(db::sql_err)?;
                let e = agg.entry(cmd.clone()).or_default();
                for row in rows {
                    let (t, h) = row.map_err(db::sql_err)?;
                    e.count += 1;
                    e.last_ms = e.last_ms.max(t);
                    e.freq += decay(t, now);
                    if host_id > 0 && h == host_id {
                        e.on_host = true;
                    }
                }
            }
        }
    }
    let list = agg
        .into_iter()
        .filter(|(cmd, _)| cmd != prefix.trim_end() || prefix.is_empty())
        .map(|(cmd, a)| {
            let mut score = a.freq;
            let mut source = "history";
            if a.on_host {
                score *= SAME_HOST_BOOST;
                source = "host";
            }
            if fts_hit.contains_key(&cmd) {
                score *= FTS_BOOST;
            }
            Candidate {
                cmd,
                score,
                source,
                count: a.count,
                last_ms: a.last_ms,
            }
        })
        .collect();
    Ok(finish(list, limit))
}

/// Last committed command on `host_id` (any host when 0).
pub fn last_command(conn: &Connection, host_id: i64) -> Result<Option<String>, String> {
    let sql = if host_id > 0 {
        "SELECT cmd FROM commands WHERE host_id = ?1 ORDER BY id DESC LIMIT 1"
    } else {
        "SELECT cmd FROM commands WHERE ?1 >= 0 ORDER BY id DESC LIMIT 1"
    };
    let mut st = conn.prepare_cached(sql).map_err(db::sql_err)?;
    let mut rows = st.query(params![host_id]).map_err(db::sql_err)?;
    match rows.next().map_err(db::sql_err)? {
        Some(r) => Ok(Some(r.get::<_, String>(0).map_err(db::sql_err)?)),
        None => Ok(None),
    }
}

/// Upsert a command transition for the host and for the global row (0).
pub fn record_transition(
    conn: &Connection,
    host_id: i64,
    prev: &str,
    next: &str,
) -> Result<(), String> {
    let mut st = conn
        .prepare_cached(
            "INSERT INTO cmd_transitions(host_id, prev, next, count) VALUES (?1, ?2, ?3, 1)
             ON CONFLICT(host_id, prev, next) DO UPDATE SET count = count + 1",
        )
        .map_err(db::sql_err)?;
    st.execute(params![0i64, prev, next]).map_err(db::sql_err)?;
    if host_id > 0 {
        st.execute(params![host_id, prev, next])
            .map_err(db::sql_err)?;
    }
    Ok(())
}

fn transitions(conn: &Connection, host_id: i64, prev: &str) -> Result<Vec<(String, i64)>, String> {
    let mut st = conn
        .prepare_cached(
            "SELECT next, count FROM cmd_transitions WHERE host_id = ?1 AND prev = ?2
             ORDER BY count DESC LIMIT 50",
        )
        .map_err(db::sql_err)?;
    let rows = st
        .query_map(params![host_id, prev], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))
        })
        .map_err(db::sql_err)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(db::sql_err)
}

/// Most likely commands after the last one executed on `host_id`.
/// Falls back to the global chain, then to plain frequency.
pub fn predict_next(
    conn: &Connection,
    host_id: i64,
    limit: usize,
) -> Result<Vec<Candidate>, String> {
    let now = now_ms() as i64;
    let Some(prev) = last_command(conn, host_id)? else {
        return complete(conn, host_id, "", limit);
    };
    let mut chain = if host_id > 0 {
        transitions(conn, host_id, &prev)?
    } else {
        Vec::new()
    };
    if chain.is_empty() {
        chain = transitions(conn, 0, &prev)?;
    }
    if chain.is_empty() {
        return complete(conn, host_id, "", limit);
    }
    let agg = aggregate(conn, host_id, None, now)?;
    let list = chain
        .into_iter()
        .map(|(cmd, count)| {
            let a = agg.get(&cmd);
            let freq = a.map(|a| a.freq).unwrap_or(0.0);
            let mut score = count as f64 * TRANSITION_WEIGHT + freq;
            if a.map(|a| a.on_host).unwrap_or(false) {
                score *= SAME_HOST_BOOST;
            }
            Candidate {
                cmd,
                score,
                source: "pattern",
                count,
                last_ms: a.map(|a| a.last_ms).unwrap_or(0),
            }
        })
        .collect();
    Ok(finish(list, limit))
}

#[cfg(test)]
mod tests {
    use super::*;

    const DAY: i64 = 24 * 3600 * 1000;

    fn add(conn: &Connection, host: i64, cmd: &str, ts: i64) {
        conn.execute(
            "INSERT INTO commands(session_id, host_id, ts_ms, cmd) VALUES (1, ?1, ?2, ?3)",
            params![host, ts, cmd],
        )
        .expect("insert");
        let id = conn.last_insert_rowid();
        conn.execute(
            "INSERT INTO commands_fts(rowid, cmd) VALUES (?1, ?2)",
            params![id, cmd],
        )
        .expect("fts");
    }

    #[test]
    fn decay_halves_every_seven_days() {
        let now = 1_700_000_000_000;
        assert!((decay(now, now) - 1.0).abs() < 1e-9);
        assert!((decay(now - 7 * DAY, now) - 0.5).abs() < 1e-9);
        assert!((decay(now - 14 * DAY, now) - 0.25).abs() < 1e-9);
        assert!((decay(now + DAY, now) - 1.0).abs() < 1e-9, "future = fresh");
    }

    #[test]
    fn frequency_recency_and_host_ranking() {
        let conn = db::open_memory().expect("db");
        let now = now_ms() as i64;
        // "git status": 5 times, 30 days old -> freq ~ 5 * 0.05 = 0.26
        for i in 0..5 {
            add(&conn, 1, "git status", now - 30 * DAY - i);
        }
        // "git stash": once, fresh -> freq 1.0 (recency beats stale frequency)
        add(&conn, 1, "git stash", now);
        // "git switch main": 3 times fresh on host 2 -> 3.0
        for i in 0..3 {
            add(&conn, 2, "git switch main", now - i);
        }
        let c = complete(&conn, 0, "git s", 10).expect("complete");
        let cmds: Vec<&str> = c.iter().map(|x| x.cmd.as_str()).collect();
        assert_eq!(cmds, vec!["git switch main", "git stash", "git status"]);
        assert_eq!(c[0].count, 3);
        assert_eq!(c[0].source, "history");
        assert!(c[2].score < c[1].score);
        // Same-host boost lifts host-1 commands on host 1.
        let c = complete(&conn, 1, "git s", 10).expect("complete");
        assert_eq!(c[0].cmd, "git switch main", "3.0 still beats 1.5");
        assert_eq!(c[1].cmd, "git stash");
        assert_eq!(c[1].source, "host");
        assert!(
            (c[1].score - SAME_HOST_BOOST * FTS_BOOST).abs() < 0.05,
            "{}",
            c[1].score
        );
        // Empty prefix = top frequent, across hosts.
        let top = complete(&conn, 0, "", 2).expect("complete");
        assert_eq!(top.len(), 2);
        assert_eq!(top[0].cmd, "git switch main");
        // Limit is capped.
        assert_eq!(clamp_limit(500), MAX_LIMIT);
        assert_eq!(clamp_limit(0), 10);
    }

    #[test]
    fn prefix_semantics_and_cjk() {
        let conn = db::open_memory().expect("db");
        let now = now_ms() as i64;
        add(&conn, 1, "echo 세션 이름", now);
        add(&conn, 1, "echo 세션 목록", now - 1);
        add(&conn, 1, "ls -la", now - 2);
        add(&conn, 1, "LS_COLORS=1 ls", now - 3);
        let c = complete(&conn, 0, "echo 세", 10).expect("complete");
        assert_eq!(c.len(), 2, "{:?}", c);
        assert_eq!(c[0].cmd, "echo 세션 이름");
        let c = complete(&conn, 0, "echo 세션 이", 10).expect("complete");
        assert_eq!(c.len(), 1);
        assert_eq!(c[0].cmd, "echo 세션 이름");
        // Case-insensitive literal prefix.
        let c = complete(&conn, 0, "ls", 10).expect("complete");
        let cmds: Vec<&str> = c.iter().map(|x| x.cmd.as_str()).collect();
        assert!(cmds.contains(&"ls -la"), "{:?}", cmds);
        assert!(cmds.contains(&"LS_COLORS=1 ls"), "{:?}", cmds);
        // Token (BM25) match without a literal prefix still surfaces.
        let c = complete(&conn, 0, "이름", 10).expect("complete");
        assert_eq!(c.len(), 1);
        assert_eq!(c[0].cmd, "echo 세션 이름");
        // The exact command already typed is not offered again.
        let c = complete(&conn, 0, "ls -la", 10).expect("complete");
        assert!(c.iter().all(|x| x.cmd != "ls -la"));
        assert!(complete(&conn, 0, "zzz", 10).expect("complete").is_empty());
    }

    #[test]
    fn predict_next_uses_transitions_then_falls_back() {
        let conn = db::open_memory().expect("db");
        let now = now_ms() as i64;
        assert!(predict_next(&conn, 1, 5).expect("empty").is_empty());
        add(&conn, 1, "cd x", now - 3);
        add(&conn, 1, "ls", now - 2);
        record_transition(&conn, 1, "cd x", "ls").expect("t");
        add(&conn, 1, "cd x", now - 1);
        add(&conn, 1, "ls", now);
        record_transition(&conn, 1, "cd x", "ls").expect("t");
        add(&conn, 1, "cd x", now);
        let p = predict_next(&conn, 1, 5).expect("predict");
        assert_eq!(p[0].cmd, "ls");
        assert_eq!(p[0].source, "pattern");
        assert_eq!(p[0].count, 2);
        assert!(p[0].score > 4.0);
        // Host 7 has no chain of its own: global chain (host 0 rows) is used.
        add(&conn, 7, "cd x", now);
        let p = predict_next(&conn, 7, 5).expect("predict");
        assert_eq!(p[0].cmd, "ls");
        // No chain at all for the last command: frequency fallback.
        add(&conn, 1, "whoami", now);
        let p = predict_next(&conn, 1, 5).expect("predict");
        assert_eq!(p[0].source, "host");
        assert_eq!(p[0].cmd, "cd x");
        assert!(!p.is_empty());
    }
}
