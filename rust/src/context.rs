//! Context bundle for the AI sidekick and the stats summary.

use rusqlite::Connection;
use serde_json::{json, Value};

use crate::db;
use crate::patterns;
use crate::record;
use crate::session;

/// Resolve a live slot id to its recorded sessions.id (or treat the number
/// as a sessions.id when no live session sits in that slot).
pub fn resolve_session_db_id(id: i32) -> Option<i64> {
    if id < 0 {
        return None;
    }
    match session::get(id) {
        Some(s) => record::db_session_id(&s),
        None => Some(id as i64),
    }
}

fn live_sessions_json() -> Vec<Value> {
    session::live()
        .iter()
        .map(|s| {
            json!({
                "id": s.id, "name": s.name(), "host": s.params.host, "user": s.params.user,
                "port": s.params.port, "state": s.state(),
                "host_id": s.host_id.load(std::sync::atomic::Ordering::Relaxed),
            })
        })
        .collect()
}

pub fn context(
    conn: &Connection,
    scene: &str,
    session_id: i32,
    max_chars: usize,
) -> Result<Value, String> {
    let max_chars = if max_chars == 0 { 4000 } else { max_chars };
    let live = session::get(session_id);
    let session_json = live.as_ref().map(|s| {
        let (cols, rows) = (
            s.cols.load(std::sync::atomic::Ordering::Relaxed),
            s.rows.load(std::sync::atomic::Ordering::Relaxed),
        );
        json!({"id": s.id, "name": s.name(), "host": s.params.host, "user": s.params.user,
               "port": s.params.port, "cols": cols, "rows": rows, "state": s.state(),
               "title": s.term().title().to_string()})
    });
    let host_id = live
        .as_ref()
        .map(|s| s.host_id.load(std::sync::atomic::Ordering::Relaxed))
        .unwrap_or(0);
    let transcript_tail = match resolve_session_db_id(session_id) {
        Some(db_id) => record::transcript(conn, db_id, max_chars)?,
        None => String::new(),
    };
    // Prefer the live screen when there is no recording (recording off).
    let transcript_tail = if transcript_tail.is_empty() {
        live.as_ref()
            .map(|s| {
                let c = s.term().contents();
                let c = c.trim_end().to_string();
                if c.len() > max_chars {
                    let mut start = c.len() - max_chars;
                    while !c.is_char_boundary(start) {
                        start += 1;
                    }
                    c[start..].to_string()
                } else {
                    c
                }
            })
            .unwrap_or_default()
    } else {
        transcript_tail
    };
    let recent = record::recent_commands(conn, host_id, 20)?;
    let now_bucket = patterns::hour_bucket(session::now_ms() as i64);
    let suggestions = patterns::suggest(conn, scene, "", now_bucket, 5)?;
    Ok(json!({
        "scene": scene,
        "session": session_json,
        "live_sessions": live_sessions_json(),
        "recent_commands": recent,
        "transcript_tail": transcript_tail,
        "frequent_hosts": db::frequent_hosts(conn, 5)?,
        "suggestions": suggestions,
        "stats": stats(conn)?,
        "generated_ms": session::now_ms(),
    }))
}

pub fn stats(conn: &Connection) -> Result<Value, String> {
    let counts = json!({
        "hosts": db::table_count(conn, "hosts"),
        "sessions": db::table_count(conn, "sessions"),
        "io_chunks": db::table_count(conn, "io_chunks"),
        "commands": db::table_count(conn, "commands"),
        "events": db::table_count(conn, "events"),
        "ai_messages": db::table_count(conn, "ai_messages"),
        "embeddings": db::table_count(conn, "embeddings"),
        "transcript_windows": db::table_count(conn, "transcripts_fts"),
        "transitions": db::table_count(conn, "transitions"),
    });
    let io_bytes: i64 = conn
        .query_row(
            "SELECT COALESCE(SUM(LENGTH(bytes)), 0) FROM io_chunks",
            [],
            |r| r.get(0),
        )
        .unwrap_or(0);
    Ok(json!({
        "counts": counts,
        "db_bytes": db::db_size_bytes(conn),
        "io_bytes": io_bytes,
        "record_max_bytes": record::max_bytes(conn),
        "record_enabled": record::enabled_cached(),
        "embed_available": crate::embed::available_with(conn),
        "embed_pending": crate::embed::pending_count(conn),
        "live_sessions": session::count(),
        "top_hosts": db::frequent_hosts(conn, 5)?,
        "top_commands": record::top_commands(conn, 10)?,
        "data_dir": db::data_dir().to_string_lossy(),
    }))
}
