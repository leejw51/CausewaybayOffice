//! Notes: free text the user types into the AI panel's note mode. Kept in
//! sqlite regardless of the recording opt-in (they are deliberate input),
//! indexed in `notes_fts` for BM25 and picked up by the embedding worker
//! (kind "note") when OpenAI indexing is enabled.

use rusqlite::{params, Connection};
use serde_json::{json, Value};

use crate::db;
use crate::embed;
use crate::session::now_ms;

/// Longest note accepted (chars).
pub const MAX_CHARS: usize = 20_000;
/// Snippet length in search hits (chars).
pub const SNIPPET_CHARS: usize = 400;
pub const TITLE_CHARS: usize = 60;

/// First line of a note, clipped.
pub fn title(text: &str) -> String {
    let line = text.lines().find(|l| !l.trim().is_empty()).unwrap_or("");
    clip(line.trim(), TITLE_CHARS)
}

pub fn snippet(text: &str) -> String {
    clip(text.trim(), SNIPPET_CHARS)
}

fn clip(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let mut out: String = s.chars().take(max).collect();
    out.push('…');
    out
}

pub fn add(conn: &Connection, text: &str, session_id: i64) -> Result<i64, String> {
    let text = text.trim_end();
    if text.trim().is_empty() {
        return Err("note is empty".into());
    }
    if text.chars().count() > MAX_CHARS {
        return Err(format!("note longer than {} characters", MAX_CHARS));
    }
    conn.execute(
        "INSERT INTO notes(ts_ms, text, session_id) VALUES (?1, ?2, ?3)",
        params![now_ms() as i64, text, session_id],
    )
    .map_err(db::sql_err)?;
    let id = conn.last_insert_rowid();
    conn.execute(
        "INSERT INTO notes_fts(rowid, text) VALUES (?1, ?2)",
        params![id, text],
    )
    .map_err(db::sql_err)?;
    // Offline: the local vector is cheap, so the note is searchable by the
    // vector pass at once. With OpenAI indexing the worker embeds it shortly.
    if !embed::available_with(conn) {
        embed::store(
            conn,
            "note",
            id,
            embed::LOCAL_MODEL,
            &embed::local_vec(text),
        )?;
    }
    Ok(id)
}

/// Remove a note, its FTS row and its embedding. Ok(false) when unknown.
pub fn delete(conn: &Connection, id: i64) -> Result<bool, String> {
    let n = conn
        .execute("DELETE FROM notes WHERE id = ?1", params![id])
        .map_err(db::sql_err)?;
    conn.execute("DELETE FROM notes_fts WHERE rowid = ?1", params![id])
        .map_err(db::sql_err)?;
    embed::remove(conn, "note", id)?;
    Ok(n > 0)
}

pub fn to_json(id: i64, ts_ms: i64, text: &str, session_id: i64) -> Value {
    json!({"id": id, "ts_ms": ts_ms, "text": text, "session_id": session_id})
}

/// Newest first: [{id, ts_ms, text, session_id}].
pub fn list(conn: &Connection, limit: usize) -> Result<Vec<Value>, String> {
    let mut st = conn
        .prepare("SELECT id, ts_ms, text, session_id FROM notes ORDER BY id DESC LIMIT ?1")
        .map_err(db::sql_err)?;
    let rows = st
        .query_map(params![limit.max(1) as i64], |r| {
            Ok(to_json(
                r.get(0)?,
                r.get(1)?,
                &r.get::<_, String>(2)?,
                r.get(3)?,
            ))
        })
        .map_err(db::sql_err)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(db::sql_err)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::search;

    #[test]
    fn add_list_search_delete() {
        let conn = db::open_memory().expect("db");
        assert!(add(&conn, "   \n", 0).is_err(), "blank notes are rejected");
        let a = add(
            &conn,
            "restart nginx after cert renew\nsudo systemctl restart nginx",
            3,
        )
        .expect("add");
        let b = add(&conn, "銅鑼灣 office wifi password in the drawer", 0).expect("add");
        assert!(b > a);
        let all = list(&conn, 10).expect("list");
        assert_eq!(all.len(), 2);
        assert_eq!(all[0]["id"], b, "newest first");
        assert_eq!(all[1]["session_id"], 3);
        let hits = search::bm25(&conn, "nginx", &["note"], 10).expect("bm25");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].id, a);
        assert_eq!(hits[0].title, "restart nginx after cert renew");
        assert!(hits[0].snippet.contains("systemctl"));
        let hits = search::bm25(&conn, "銅鑼灣", &search::ALL_KINDS, 10).expect("bm25");
        assert_eq!(hits.len(), 1, "notes are part of the global search");
        assert_eq!(hits[0].kind, "note");
        assert_eq!(
            embed::pending_count(&conn),
            0,
            "offline notes get a local vector at once"
        );
        assert_eq!(embed::load_all(&conn).expect("load").len(), 2);
        assert!(delete(&conn, a).expect("delete"));
        assert!(!delete(&conn, a).expect("delete again"));
        assert!(search::bm25(&conn, "nginx", &["note"], 10)
            .expect("bm25")
            .is_empty());
        assert_eq!(
            embed::load_all(&conn).expect("load").len(),
            1,
            "embedding removed"
        );
        assert!(search::describe(&conn, "note", b).expect("d").is_some());
    }

    #[test]
    fn hybrid_finds_notes_offline_by_fragments() {
        let conn = db::open_memory().expect("db");
        embed::invalidate_cache();
        let a = add(&conn, "nginx certificates renewed on the causeway box", 0).expect("add");
        add(&conn, "lunch at the dim sum place near the tram", 0).expect("add");
        assert_eq!(
            embed::run_local_all(&conn).expect("local vectors"),
            0,
            "already embedded"
        );
        // An inflection BM25 cannot prefix-match: "renewal" vs "renewed".
        let lex = search::bm25(&conn, "renewal", &["note"], 10).expect("bm25");
        assert!(lex.is_empty(), "BM25 alone misses the inflection");
        let hits = search::hybrid(&conn, "certificate renewal", &["note"], 10).expect("hybrid");
        assert_eq!(
            hits[0].id, a,
            "vector pass ranks the shared fragments first"
        );
        assert!(hits[0].sources.contains(&"semantic"));
        embed::invalidate_cache();
    }

    #[test]
    fn title_and_snippet_clip() {
        assert_eq!(title("\n\n  hello world  \nmore"), "hello world");
        let long: String = "x".repeat(TITLE_CHARS + 5);
        assert_eq!(title(&long).chars().count(), TITLE_CHARS + 1);
        assert!(title(&long).ends_with('…'));
        assert_eq!(snippet("  a  "), "a");
    }
}
