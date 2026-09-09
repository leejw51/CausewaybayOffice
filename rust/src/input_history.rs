//! Local field history. Only named, non-secret UI fields are accepted.
use rusqlite::{params, Connection};

fn allowed(field: &str) -> bool {
    matches!(
        field,
        "connect.host"
            | "connect.port"
            | "connect.user"
            | "connect.keypath"
            | "search.sessions"
            | "search.map2"
            | "search.history"
            | "rename"
            | "ai.prompt"
            | "settings.model_openai"
            | "settings.model_anthropic"
            | "settings.model_xai"
    )
}
fn validate(field: &str, value: &str) -> Result<(), String> {
    if !allowed(field) {
        return Err("field is not eligible for input history".into());
    }
    if value.len() > 16384 || value.chars().any(char::is_control) {
        return Err("invalid field value".into());
    }
    Ok(())
}
pub fn save(conn: &Connection, field: &str, value: &str, commit: bool) -> Result<(), String> {
    validate(field, value)?;
    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    crate::db::kv_set(&tx, &format!("input.draft.{field}"), value)?;
    if commit && !value.trim().is_empty() {
        tx.execute(
            "INSERT INTO input_history(field,value,folded,uses,updated_ms) VALUES(?1,?2,?3,1,?4)
          ON CONFLICT(field,value) DO UPDATE SET uses=uses+1,updated_ms=excluded.updated_ms",
            params![
                field,
                value,
                value.to_lowercase(),
                crate::session::now_ms() as i64
            ],
        )
        .map_err(|e| e.to_string())?;
        tx.execute("DELETE FROM input_history WHERE field=?1 AND value NOT IN
          (SELECT value FROM input_history WHERE field=?1 ORDER BY updated_ms DESC,rowid DESC LIMIT 100)",
          [field]).map_err(|e| e.to_string())?;
    }
    tx.commit().map_err(|e| e.to_string())
}
pub fn search(
    conn: &Connection,
    field: &str,
    query: &str,
    limit: usize,
) -> Result<Vec<String>, String> {
    validate(field, query)?;
    let mut stmt = conn
        .prepare(
            "SELECT value FROM input_history WHERE field=?1 AND instr(folded,?2)>0
        ORDER BY (instr(folded,?2)=1) DESC, updated_ms DESC, uses DESC, rowid DESC LIMIT ?3",
        )
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map(
            params![field, query.to_lowercase(), limit.min(20) as i64],
            |r| r.get(0),
        )
        .map_err(|e| e.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string());
    rows
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn drafts_history_unicode_literals_and_secret_exclusion() {
        let db = crate::db::open_memory().unwrap();
        save(&db, "connect.host", "server-old", true).unwrap();
        save(&db, "connect.host", "server-draft", false).unwrap();
        assert_eq!(
            crate::db::kv_get(&db, "input.draft.connect.host")
                .unwrap()
                .as_deref(),
            Some("server-draft")
        );
        assert_eq!(
            search(&db, "connect.host", "server", 20).unwrap(),
            ["server-old"]
        );
        save(&db, "rename", "香港 ÄBC 100%_", true).unwrap();
        assert_eq!(search(&db, "rename", "äbc", 20).unwrap().len(), 1);
        assert_eq!(search(&db, "rename", "%_", 20).unwrap().len(), 1);
        assert!(search(&db, "rename", "' OR 1=1 --", 20).unwrap().is_empty());
        assert!(save(&db, "connect.password", "secret", true).is_err());
        assert!(save(&db, "settings.key_openai", "secret", true).is_err());
        assert!(search(&db, "connect.user", "server", 20)
            .unwrap()
            .is_empty());
        assert!(save(&db, "rename", "bad\nline", true).is_err());
    }
    #[test]
    fn history_is_bounded_and_deduplicated() {
        let db = crate::db::open_memory().unwrap();
        for i in 0..120 {
            save(&db, "connect.host", &format!("host-{i}"), true).unwrap();
        }
        save(&db, "connect.host", "host-119", true).unwrap();
        let count: i64 = db
            .query_row("SELECT count(*) FROM input_history", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 100);
        assert!(search(&db, "connect.host", "host-0", 20)
            .unwrap()
            .is_empty());
        assert_eq!(search(&db, "connect.host", "", 999).unwrap().len(), 20);
    }
}
