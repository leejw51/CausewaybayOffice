//! Persistent search over the recording: BM25 (sqlite FTS5) + semantic
//! (embeddings, cosine), fused with reciprocal rank fusion.

use std::collections::HashMap;

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

use crate::db;
use crate::embed;

pub const RRF_K: f64 = 60.0;
pub const ALL_KINDS: [&str; 7] = [
    "host",
    "session",
    "command",
    "transcript",
    "ai",
    "event",
    "note",
];

#[derive(Clone, Debug, PartialEq)]
pub struct Hit {
    pub kind: String,
    pub id: i64,
    pub score: f64,
    pub title: String,
    pub snippet: String,
    pub ts_ms: i64,
    pub host_id: i64,
    pub session_id: i64,
    pub sources: Vec<&'static str>,
}

impl Hit {
    pub fn to_json(&self) -> Value {
        json!({
            "kind": self.kind, "id": self.id, "score": (self.score * 10000.0).round() / 10000.0,
            "title": self.title, "snippet": self.snippet, "ts_ms": self.ts_ms,
            "host_id": self.host_id, "session_id": self.session_id, "sources": self.sources,
        })
    }
}

pub fn to_json(hits: &[Hit]) -> Value {
    Value::Array(hits.iter().map(Hit::to_json).collect())
}

/// "host,command" -> kinds; "" or unknown-only -> all.
pub fn parse_kinds(csv: &str) -> Vec<&'static str> {
    let wanted: Vec<&'static str> = csv
        .split(',')
        .map(|s| s.trim().to_ascii_lowercase())
        .filter_map(|s| ALL_KINDS.iter().find(|k| **k == s).copied())
        .collect();
    if wanted.is_empty() {
        ALL_KINDS.to_vec()
    } else {
        wanted
    }
}

/// Turn free text into a safe FTS5 MATCH expression: every token quoted,
/// prefix-matched, implicitly ANDed.
pub fn fts_query(q: &str) -> String {
    q.split(|c: char| c.is_whitespace() || c == '"')
        .filter(|t| !t.is_empty())
        .map(|t| format!("\"{}\"*", t.replace('"', "\"\"")))
        .collect::<Vec<_>>()
        .join(" ")
}

// ---------------------------------------------------------------- bm25

fn fts_hits(
    conn: &Connection,
    kind: &'static str,
    sql: &str,
    q: &str,
    limit: usize,
    map: impl Fn(&rusqlite::Row) -> rusqlite::Result<Hit>,
) -> Result<Vec<Hit>, String> {
    let mut st = conn.prepare(sql).map_err(db::sql_err)?;
    let rows = st
        .query_map(params![q, limit as i64], |r| map(r))
        .map_err(|e| format!("{} search: {}", kind, e))?;
    rows.collect::<Result<Vec<_>, _>>().map_err(db::sql_err)
}

/// BM25 hits per kind (score = -bm25, higher is better), best first.
pub fn bm25(
    conn: &Connection,
    query: &str,
    kinds: &[&'static str],
    limit: usize,
) -> Result<Vec<Hit>, String> {
    let q = fts_query(query);
    if q.is_empty() {
        return Ok(Vec::new());
    }
    let mut all: Vec<Hit> = Vec::new();
    for &kind in kinds {
        let hits = match kind {
            "command" => fts_hits(
                conn,
                kind,
                "SELECT c.id, c.cmd, c.ts_ms, c.host_id, c.session_id, bm25(commands_fts)
                 FROM commands_fts f JOIN commands c ON c.id = f.rowid
                 WHERE commands_fts MATCH ?1 ORDER BY bm25(commands_fts) LIMIT ?2",
                &q,
                limit,
                |r| {
                    Ok(Hit {
                        kind: "command".into(),
                        id: r.get(0)?,
                        title: r.get(1)?,
                        snippet: r.get(1)?,
                        ts_ms: r.get(2)?,
                        host_id: r.get(3)?,
                        session_id: r.get(4)?,
                        score: -r.get::<_, f64>(5)?,
                        sources: vec!["bm25"],
                    })
                },
            )?,
            "transcript" => fts_hits(
                conn,
                kind,
                "SELECT t.rowid, t.session_id, snippet(transcripts_fts, 1, '', '', '…', 16),
                        bm25(transcripts_fts), COALESCE(s.started_ms, 0), COALESCE(s.host_id, 0), COALESCE(s.name, '')
                 FROM transcripts_fts t LEFT JOIN sessions s ON s.id = t.session_id
                 WHERE transcripts_fts MATCH ?1 ORDER BY bm25(transcripts_fts) LIMIT ?2",
                &q,
                limit,
                |r| {
                    let name: String = r.get(6)?;
                    let sid: i64 = r.get(1)?;
                    Ok(Hit {
                        kind: "transcript".into(),
                        id: r.get(0)?,
                        title: if name.is_empty() { format!("session {}", sid) } else { name },
                        snippet: r.get(2)?,
                        score: -r.get::<_, f64>(3)?,
                        ts_ms: r.get(4)?,
                        host_id: r.get(5)?,
                        session_id: sid,
                        sources: vec!["bm25"],
                    })
                },
            )?,
            "ai" => fts_hits(
                conn,
                kind,
                "SELECT a.id, a.role, a.provider, snippet(ai_fts, 0, '', '', '…', 16), a.ts_ms, a.session_id, bm25(ai_fts)
                 FROM ai_fts f JOIN ai_messages a ON a.id = f.rowid
                 WHERE ai_fts MATCH ?1 ORDER BY bm25(ai_fts) LIMIT ?2",
                &q,
                limit,
                |r| {
                    Ok(Hit {
                        kind: "ai".into(),
                        id: r.get(0)?,
                        title: format!("{} ({})", r.get::<_, String>(1)?, r.get::<_, String>(2)?),
                        snippet: r.get(3)?,
                        ts_ms: r.get(4)?,
                        host_id: 0,
                        session_id: r.get(5)?,
                        score: -r.get::<_, f64>(6)?,
                        sources: vec!["bm25"],
                    })
                },
            )?,
            "host" => fts_hits(
                conn,
                kind,
                "SELECT h.id, h.name, h.user, h.host, h.port, h.tags, h.last_used_ms, bm25(hosts_fts)
                 FROM hosts_fts f JOIN hosts h ON h.id = f.rowid
                 WHERE hosts_fts MATCH ?1 ORDER BY bm25(hosts_fts) LIMIT ?2",
                &q,
                limit,
                |r| {
                    let name: String = r.get(1)?;
                    let addr = format!("{}@{}:{}", r.get::<_, String>(2)?, r.get::<_, String>(3)?, r.get::<_, i64>(4)?);
                    let tags: String = r.get(5)?;
                    Ok(Hit {
                        kind: "host".into(),
                        id: r.get(0)?,
                        title: if name.is_empty() { addr.clone() } else { name },
                        snippet: if tags.is_empty() { addr } else { format!("{} [{}]", addr, tags) },
                        ts_ms: r.get(6)?,
                        host_id: r.get(0)?,
                        session_id: 0,
                        score: -r.get::<_, f64>(7)?,
                        sources: vec!["bm25"],
                    })
                },
            )?,
            "event" => fts_hits(
                conn,
                kind,
                "SELECT e.id, e.kind, e.scene, e.action, snippet(events_fts, 1, '', '', '…', 16), e.ts_ms, bm25(events_fts)
                 FROM events_fts f JOIN events e ON e.id = f.rowid
                 WHERE events_fts MATCH ?1 ORDER BY bm25(events_fts) LIMIT ?2",
                &q,
                limit,
                |r| {
                    Ok(Hit {
                        kind: "event".into(),
                        id: r.get(0)?,
                        title: format!("{}/{} {}", r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, String>(3)?),
                        snippet: r.get(4)?,
                        ts_ms: r.get(5)?,
                        host_id: 0,
                        session_id: 0,
                        score: -r.get::<_, f64>(6)?,
                        sources: vec!["bm25"],
                    })
                },
            )?,
            "note" => fts_hits(
                conn,
                kind,
                "SELECT n.id, n.text, n.ts_ms, n.session_id, bm25(notes_fts)
                 FROM notes_fts f JOIN notes n ON n.id = f.rowid
                 WHERE notes_fts MATCH ?1 ORDER BY bm25(notes_fts) LIMIT ?2",
                &q,
                limit,
                |r| {
                    let text: String = r.get(1)?;
                    Ok(Hit {
                        kind: "note".into(),
                        id: r.get(0)?,
                        title: crate::notes::title(&text),
                        snippet: crate::notes::snippet(&text),
                        ts_ms: r.get(2)?,
                        host_id: 0,
                        session_id: r.get(3)?,
                        score: -r.get::<_, f64>(4)?,
                        sources: vec!["bm25"],
                    })
                },
            )?,
            "session" => session_hits(conn, query, limit)?,
            _ => Vec::new(),
        };
        all.extend(hits);
    }
    all.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    all.truncate(limit);
    Ok(all)
}

/// Sessions have no FTS table: substring match on name/host/user.
fn session_hits(conn: &Connection, query: &str, limit: usize) -> Result<Vec<Hit>, String> {
    let terms: Vec<String> = query.split_whitespace().map(|t| t.to_lowercase()).collect();
    if terms.is_empty() {
        return Ok(Vec::new());
    }
    let mut st = conn
        .prepare("SELECT id, name, host, user, port, started_ms, host_id FROM sessions ORDER BY id DESC LIMIT 2000")
        .map_err(db::sql_err)?;
    let rows = st
        .query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, i64>(4)?,
                r.get::<_, i64>(5)?,
                r.get::<_, i64>(6)?,
            ))
        })
        .map_err(db::sql_err)?;
    let mut hits = Vec::new();
    for row in rows {
        let (id, name, host, user, port, started, host_id) = row.map_err(db::sql_err)?;
        let hay = format!("{} {}@{}:{}", name, user, host, port).to_lowercase();
        if terms.iter().all(|t| hay.contains(t.as_str())) {
            hits.push(Hit {
                kind: "session".into(),
                id,
                score: 1.0,
                title: name,
                snippet: format!("{}@{}:{}", user, host, port),
                ts_ms: started,
                host_id,
                session_id: id,
                sources: vec!["bm25"],
            });
            if hits.len() >= limit {
                break;
            }
        }
    }
    Ok(hits)
}

// ------------------------------------------------------------ semantic

/// Cosine nearest neighbours over the in-memory vectors of `kinds`.
pub fn semantic(
    conn: &Connection,
    query: &str,
    kinds: &[&'static str],
    limit: usize,
) -> Result<Vec<Hit>, String> {
    if query.trim().is_empty() {
        return Ok(Vec::new());
    }
    let qv = embed::query_vec_with(conn, query)?;
    semantic_with_vector(conn, &qv, kinds, limit, embed::model_with(conn))
}

/// Nearest neighbours among the vectors of `model` only (dimensions and
/// spaces differ between models).
pub fn semantic_with_vector(
    conn: &Connection,
    qv: &[f32],
    kinds: &[&'static str],
    limit: usize,
    model: &str,
) -> Result<Vec<Hit>, String> {
    let entries = embed::entries(conn)?;
    let mut scored: Vec<(f32, &embed::Entry)> = entries
        .iter()
        .filter(|e| e.model == model && kinds.contains(&e.kind.as_str()))
        .map(|e| (embed::cosine(qv, &e.vec), e))
        .collect();
    // Local vectors share no features with an unrelated text (cosine ~0);
    // such rows are noise, not weak hits. Neural embeddings sit far from 0
    // for everything, so no floor there.
    if model == embed::LOCAL_MODEL {
        scored.retain(|(score, _)| *score >= embed::LOCAL_MIN_SCORE);
    }
    scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
    let mut hits = Vec::new();
    for (score, e) in scored.into_iter().take(limit) {
        if let Some(mut h) = describe(conn, &e.kind, e.ref_id)? {
            h.score = score as f64;
            h.sources = vec!["semantic"];
            hits.push(h);
        }
    }
    Ok(hits)
}

/// FFI-facing search: network I/O never holds the shared database mutex.
pub fn semantic_global(
    query: &str,
    kinds: &[&'static str],
    limit: usize,
) -> Result<Vec<Hit>, String> {
    if query.trim().is_empty() {
        return Ok(Vec::new());
    }
    let model = embed::model();
    let qv = embed::query_vec(query)?;
    db::with(|c| semantic_with_vector(c, &qv, kinds, limit, model))
}

/// BM25 and the vector pass always run together: local vectors need no
/// network, and a failing remote pass degrades to BM25 alone.
pub fn hybrid_global(
    query: &str,
    kinds: &[&'static str],
    limit: usize,
) -> Result<Vec<Hit>, String> {
    let pool = limit.saturating_mul(3).max(1);
    let lex = db::with(|c| bm25(c, query, kinds, pool))?;
    let sem = semantic_global(query, kinds, pool).unwrap_or_default();
    let mut fused = rrf(&[lex, sem], RRF_K);
    fused.truncate(limit);
    Ok(fused)
}

/// Title/snippet/meta for a (kind, id) pair.
pub fn describe(conn: &Connection, kind: &str, id: i64) -> Result<Option<Hit>, String> {
    let mk = |title: String, snippet: String, ts_ms: i64, host_id: i64, session_id: i64| Hit {
        kind: kind.to_string(),
        id,
        score: 0.0,
        title,
        snippet,
        ts_ms,
        host_id,
        session_id,
        sources: Vec::new(),
    };
    let hit = match kind {
        "command" => conn
            .query_row(
                "SELECT cmd, ts_ms, host_id, session_id FROM commands WHERE id = ?1",
                params![id],
                |r| {
                    let cmd: String = r.get(0)?;
                    Ok(mk(cmd.clone(), cmd, r.get(1)?, r.get(2)?, r.get(3)?))
                },
            )
            .optional(),
        "transcript" => conn
            .query_row(
                "SELECT t.session_id, substr(t.text, 1, 160), COALESCE(s.started_ms,0), COALESCE(s.host_id,0), COALESCE(s.name,'')
                 FROM transcripts_fts t LEFT JOIN sessions s ON s.id = t.session_id WHERE t.rowid = ?1",
                params![id],
                |r| {
                    let sid: i64 = r.get(0)?;
                    let name: String = r.get(4)?;
                    Ok(mk(
                        if name.is_empty() { format!("session {}", sid) } else { name },
                        r.get(1)?,
                        r.get(2)?,
                        r.get(3)?,
                        sid,
                    ))
                },
            )
            .optional(),
        "ai" => conn
            .query_row(
                "SELECT role, provider, substr(content, 1, 160), ts_ms, session_id FROM ai_messages WHERE id = ?1",
                params![id],
                |r| {
                    Ok(mk(
                        format!("{} ({})", r.get::<_, String>(0)?, r.get::<_, String>(1)?),
                        r.get(2)?,
                        r.get(3)?,
                        0,
                        r.get(4)?,
                    ))
                },
            )
            .optional(),
        "host" => conn
            .query_row(
                "SELECT name, user, host, port, tags, last_used_ms FROM hosts WHERE id = ?1",
                params![id],
                |r| {
                    let name: String = r.get(0)?;
                    let addr = format!("{}@{}:{}", r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, i64>(3)?);
                    let tags: String = r.get(4)?;
                    Ok(mk(
                        if name.is_empty() { addr.clone() } else { name },
                        if tags.is_empty() { addr } else { format!("{} [{}]", addr, tags) },
                        r.get(5)?,
                        id,
                        0,
                    ))
                },
            )
            .optional(),
        "event" => conn
            .query_row(
                "SELECT kind, scene, action, substr(data_json, 1, 160), ts_ms FROM events WHERE id = ?1",
                params![id],
                |r| {
                    Ok(mk(
                        format!("{}/{} {}", r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?),
                        r.get(3)?,
                        r.get(4)?,
                        0,
                        0,
                    ))
                },
            )
            .optional(),
        "note" => conn
            .query_row(
                "SELECT text, ts_ms, session_id FROM notes WHERE id = ?1",
                params![id],
                |r| {
                    let text: String = r.get(0)?;
                    Ok(mk(
                        crate::notes::title(&text),
                        crate::notes::snippet(&text),
                        r.get(1)?,
                        0,
                        r.get(2)?,
                    ))
                },
            )
            .optional(),
        "session" => conn
            .query_row(
                "SELECT name, user, host, port, started_ms, host_id FROM sessions WHERE id = ?1",
                params![id],
                |r| {
                    Ok(mk(
                        r.get(0)?,
                        format!("{}@{}:{}", r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, i64>(3)?),
                        r.get(4)?,
                        r.get(5)?,
                        id,
                    ))
                },
            )
            .optional(),
        _ => Ok(None),
    };
    hit.map_err(db::sql_err)
}

// ---------------------------------------------------------------- RRF

/// Reciprocal rank fusion of several ranked lists (best first each).
pub fn rrf(lists: &[Vec<Hit>], k: f64) -> Vec<Hit> {
    let mut fused: HashMap<(String, i64), Hit> = HashMap::new();
    let mut order: Vec<(String, i64)> = Vec::new();
    for list in lists {
        for (rank, h) in list.iter().enumerate() {
            let key = (h.kind.clone(), h.id);
            let contrib = 1.0 / (k + rank as f64 + 1.0);
            match fused.get_mut(&key) {
                Some(f) => {
                    f.score += contrib;
                    for s in &h.sources {
                        if !f.sources.contains(s) {
                            f.sources.push(s);
                        }
                    }
                }
                None => {
                    let mut f = h.clone();
                    f.score = contrib;
                    fused.insert(key.clone(), f);
                    order.push(key);
                }
            }
        }
    }
    let mut out: Vec<Hit> = order.into_iter().filter_map(|k| fused.remove(&k)).collect();
    out.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(b.ts_ms.cmp(&a.ts_ms))
    });
    out
}

/// BM25 + semantic (when available) fused by RRF.
pub fn hybrid(
    conn: &Connection,
    query: &str,
    kinds: &[&'static str],
    limit: usize,
) -> Result<Vec<Hit>, String> {
    let pool = limit.max(1) * 3;
    let lex = bm25(conn, query, kinds, pool)?;
    let sem = semantic(conn, query, kinds, pool).unwrap_or_default();
    let mut fused = rrf(&[lex, sem], RRF_K);
    fused.truncate(limit.max(1));
    Ok(fused)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn h(kind: &str, id: i64, ts: i64) -> Hit {
        Hit {
            kind: kind.into(),
            id,
            score: 0.0,
            title: String::new(),
            snippet: String::new(),
            ts_ms: ts,
            host_id: 0,
            session_id: 0,
            sources: vec![if ts % 2 == 0 { "bm25" } else { "semantic" }],
        }
    }

    #[test]
    fn rrf_fuses_and_merges_sources() {
        let a = vec![h("command", 1, 0), h("command", 2, 0), h("command", 3, 0)];
        let b = vec![h("command", 3, 1), h("command", 1, 1), h("host", 9, 1)];
        let f = rrf(&[a, b], 60.0);
        assert_eq!(f[0].id, 1, "1 is rank 1 + rank 2");
        assert_eq!(f[1].id, 3, "3 is rank 3 + rank 1");
        assert_eq!(f[0].sources, vec!["bm25", "semantic"]);
        let expected = 1.0 / 61.0 + 1.0 / 62.0;
        assert!((f[0].score - expected).abs() < 1e-9);
        assert_eq!(f.len(), 4);
        assert_eq!(f[3].kind, "host");
        assert_eq!(f[3].sources, vec!["semantic"]);
    }

    #[test]
    fn kinds_and_fts_query() {
        assert_eq!(parse_kinds(""), ALL_KINDS.to_vec());
        assert_eq!(parse_kinds("command, HOST,nope"), vec!["command", "host"]);
        assert_eq!(parse_kinds("note"), vec!["note"]);
        assert_eq!(parse_kinds("nope"), ALL_KINDS.to_vec());
        assert_eq!(fts_query("git  status"), "\"git\"* \"status\"*");
        assert_eq!(fts_query("세션 이름"), "\"세션\"* \"이름\"*");
        assert_eq!(fts_query("say \"hi\""), "\"say\"* \"hi\"*");
        assert_eq!(fts_query("   "), "");
    }

    #[test]
    fn bm25_over_memory_db() {
        let conn = db::open_memory().expect("db");
        for (i, cmd) in ["git status", "git commit -m x", "ls -la", "echo 세션 이름"]
            .iter()
            .enumerate()
        {
            conn.execute(
                "INSERT INTO commands(id, session_id, host_id, ts_ms, cmd) VALUES (?1, 1, 0, ?1, ?2)",
                params![i as i64 + 1, cmd],
            )
            .expect("cmd");
            conn.execute(
                "INSERT INTO commands_fts(rowid, cmd) VALUES (?1, ?2)",
                params![i as i64 + 1, cmd],
            )
            .expect("fts");
        }
        let hits = bm25(&conn, "git status", &["command"], 10).expect("bm25");
        assert_eq!(hits[0].title, "git status");
        assert_eq!(
            hits.len(),
            1,
            "tokens are ANDed: only 'git status' has both"
        );
        assert_eq!(bm25(&conn, "git", &["command"], 10).expect("bm25").len(), 2);
        let hits = bm25(&conn, "세션 이름", &["command"], 10).expect("bm25");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].id, 4);
        assert!(bm25(&conn, "zzz", &ALL_KINDS, 10).expect("bm25").is_empty());
        let d = describe(&conn, "command", 3).expect("d").expect("row");
        assert_eq!(d.title, "ls -la");
        assert!(describe(&conn, "command", 99).expect("d").is_none());
    }
}
