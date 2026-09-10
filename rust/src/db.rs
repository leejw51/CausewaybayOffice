//! SQLite persistence at ~/.causewaybayoffice/office.db (override with the
//! CBO_HOME env var). Schema + migrations, kv, hosts, sessions, and the
//! global connection handle. Every query helper takes a `&Connection` so
//! the modules can be unit-tested on an in-memory database.

use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard, OnceLock};

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

use crate::session::{lock, now_ms};

pub const DIR_NAME: &str = ".causewaybayoffice";
pub const DB_FILE: &str = "office.db";

/// The data directory: `$CBO_HOME` or `~/.causewaybayoffice`.
pub fn data_dir() -> PathBuf {
    if let Some(p) = std::env::var_os("CBO_HOME").filter(|p| !p.is_empty()) {
        return PathBuf::from(p);
    }
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    home.join(DIR_NAME)
}

pub struct Db {
    conn: Mutex<Connection>,
    pub dir: PathBuf,
}

static DB: OnceLock<Result<Db, String>> = OnceLock::new();

/// Open (once) the database under the data directory. Idempotent.
pub fn init() -> Result<&'static Db, String> {
    DB.get_or_init(open_default).as_ref().map_err(|e| e.clone())
}

fn open_default() -> Result<Db, String> {
    let dir = data_dir();
    create_private_dir(&dir)?;
    let path = dir.join(DB_FILE);
    let conn = Connection::open(&path).map_err(|e| format!("open {}: {}", path.display(), e))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .map_err(|e| format!("secure database: {}", e))?;
    }
    conn.busy_timeout(std::time::Duration::from_secs(5))
        .map_err(|e| e.to_string())?;
    conn.execute_batch(
        "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;",
    )
    .map_err(|e| format!("pragma: {}", e))?;
    migrate(&conn)?;
    Ok(Db {
        conn: Mutex::new(conn),
        dir,
    })
}

fn create_private_dir(dir: &std::path::Path) -> Result<(), String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("create {}: {}", dir.display(), e))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
            .map_err(|e| format!("secure {}: {}", dir.display(), e))?;
    }
    Ok(())
}

impl Db {
    pub fn conn(&self) -> MutexGuard<'_, Connection> {
        lock(&self.conn)
    }
}

/// Run `f` with the global connection.
pub fn with<T>(f: impl FnOnce(&Connection) -> Result<T, String>) -> Result<T, String> {
    let db = init()?;
    let conn = db.conn();
    f(&conn)
}

pub fn sql_err(e: rusqlite::Error) -> String {
    e.to_string()
}

// ------------------------------------------------------------------ schema

const SCHEMA_V1: &str = r#"
CREATE TABLE IF NOT EXISTS kv (
  key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_ms INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS hosts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL DEFAULT '', host TEXT NOT NULL, port INTEGER NOT NULL DEFAULT 22,
  user TEXT NOT NULL, keypath TEXT NOT NULL DEFAULT '', platform TEXT NOT NULL DEFAULT '',
  tags TEXT NOT NULL DEFAULT '', created_ms INTEGER NOT NULL, last_used_ms INTEGER NOT NULL DEFAULT 0,
  use_count INTEGER NOT NULL DEFAULT 0,
  UNIQUE(user, host, port));
CREATE TABLE IF NOT EXISTS sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT, slot INTEGER NOT NULL, host_id INTEGER NOT NULL DEFAULT 0,
  name TEXT NOT NULL, host TEXT NOT NULL, port INTEGER NOT NULL, user TEXT NOT NULL,
  started_ms INTEGER NOT NULL, ended_ms INTEGER NOT NULL DEFAULT 0,
  cols INTEGER NOT NULL, rows INTEGER NOT NULL, end_state INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS sessions_started ON sessions(started_ms);
CREATE TABLE IF NOT EXISTS io_chunks (
  id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER NOT NULL, ts_ms INTEGER NOT NULL,
  dir INTEGER NOT NULL, bytes BLOB NOT NULL);
CREATE INDEX IF NOT EXISTS io_chunks_session ON io_chunks(session_id, id);
CREATE TABLE IF NOT EXISTS commands (
  id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER NOT NULL, host_id INTEGER NOT NULL DEFAULT 0,
  ts_ms INTEGER NOT NULL, cmd TEXT NOT NULL, cwd_hint TEXT NOT NULL DEFAULT '');
CREATE INDEX IF NOT EXISTS commands_ts ON commands(ts_ms);
CREATE INDEX IF NOT EXISTS commands_host ON commands(host_id, ts_ms);
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts_ms INTEGER NOT NULL, kind TEXT NOT NULL,
  scene TEXT NOT NULL DEFAULT '', action TEXT NOT NULL DEFAULT '', data_json TEXT NOT NULL DEFAULT '');
CREATE INDEX IF NOT EXISTS events_ts ON events(ts_ms);
CREATE TABLE IF NOT EXISTS ai_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts_ms INTEGER NOT NULL, provider TEXT NOT NULL DEFAULT '',
  model TEXT NOT NULL DEFAULT '', role TEXT NOT NULL DEFAULT '', content TEXT NOT NULL,
  session_id INTEGER NOT NULL DEFAULT 0, scene TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS embeddings (
  kind TEXT NOT NULL, ref_id INTEGER NOT NULL, model TEXT NOT NULL, dim INTEGER NOT NULL,
  vec BLOB NOT NULL, PRIMARY KEY(kind, ref_id));
CREATE TABLE IF NOT EXISTS transitions (
  scene TEXT NOT NULL, prev_action TEXT NOT NULL, action TEXT NOT NULL,
  hour_bucket INTEGER NOT NULL, count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(scene, prev_action, action, hour_bucket));
CREATE VIRTUAL TABLE IF NOT EXISTS commands_fts USING fts5(cmd, tokenize='unicode61');
CREATE VIRTUAL TABLE IF NOT EXISTS transcripts_fts USING fts5(session_id UNINDEXED, text, tokenize='unicode61');
CREATE VIRTUAL TABLE IF NOT EXISTS ai_fts USING fts5(content, tokenize='unicode61');
CREATE VIRTUAL TABLE IF NOT EXISTS hosts_fts USING fts5(name, host, user, tags, tokenize='unicode61');
CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(action, data, tokenize='unicode61');
"#;

/// v2: command chains for next-command prediction (host 0 = global).
const SCHEMA_V2: &str = r#"
CREATE TABLE IF NOT EXISTS cmd_transitions (
  host_id INTEGER NOT NULL, prev TEXT NOT NULL, next TEXT NOT NULL,
  count INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(host_id, prev, next));
"#;

const SCHEMA_V3: &str = r#"
CREATE TABLE IF NOT EXISTS input_history (
  field TEXT NOT NULL, value TEXT NOT NULL, folded TEXT NOT NULL,
  uses INTEGER NOT NULL DEFAULT 1, updated_ms INTEGER NOT NULL,
  UNIQUE(field,value));
CREATE INDEX IF NOT EXISTS input_history_field ON input_history(field,updated_ms DESC);
"#;

/// v4: free-form notes typed into the AI panel's note mode. Stored whether
/// or not recording is on (they are explicit user input); indexed for BM25
/// and, when indexing is enabled, embedded like every other row.
const SCHEMA_V4: &str = r#"
CREATE TABLE IF NOT EXISTS notes (
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts_ms INTEGER NOT NULL, text TEXT NOT NULL,
  session_id INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS notes_ts ON notes(ts_ms);
CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(text, tokenize='unicode61');
"#;

/// Apply pending migrations. Safe to call repeatedly.
pub fn migrate(conn: &Connection) -> Result<(), String> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS migrations (version INTEGER PRIMARY KEY, applied_ms INTEGER NOT NULL);",
    )
    .map_err(sql_err)?;
    let current: i64 = conn
        .query_row(
            "SELECT COALESCE(MAX(version), 0) FROM migrations",
            [],
            |r| r.get(0),
        )
        .map_err(sql_err)?;
    let steps: &[(i64, &str)] = &[
        (1, SCHEMA_V1),
        (2, SCHEMA_V2),
        (3, SCHEMA_V3),
        (4, SCHEMA_V4),
    ];
    for (version, sql) in steps {
        if *version <= current {
            continue;
        }
        conn.execute_batch(sql)
            .map_err(|e| format!("migration {}: {}", version, e))?;
        conn.execute(
            "INSERT INTO migrations(version, applied_ms) VALUES (?1, ?2)",
            params![version, now_ms() as i64],
        )
        .map_err(sql_err)?;
    }
    Ok(())
}

pub fn schema_version(conn: &Connection) -> i64 {
    conn.query_row(
        "SELECT COALESCE(MAX(version), 0) FROM migrations",
        [],
        |r| r.get(0),
    )
    .unwrap_or(0)
}

/// Open an in-memory database with the full schema (tests).
pub fn open_memory() -> Result<Connection, String> {
    let conn = Connection::open_in_memory().map_err(sql_err)?;
    migrate(&conn)?;
    Ok(conn)
}

pub fn fts5_available(conn: &Connection) -> bool {
    conn.execute_batch(
        "CREATE VIRTUAL TABLE IF NOT EXISTS _fts5_probe USING fts5(x); DROP TABLE _fts5_probe;",
    )
    .is_ok()
}

// ---------------------------------------------------------------------- kv

pub fn kv_set(conn: &Connection, key: &str, value: &str) -> Result<(), String> {
    conn.execute(
        "INSERT INTO kv(key, value, updated_ms) VALUES (?1, ?2, ?3)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_ms = excluded.updated_ms",
        params![key, value, now_ms() as i64],
    )
    .map(|_| ())
    .map_err(sql_err)
}

pub fn kv_get(conn: &Connection, key: &str) -> Result<Option<String>, String> {
    conn.query_row("SELECT value FROM kv WHERE key = ?1", params![key], |r| {
        r.get(0)
    })
    .optional()
    .map_err(sql_err)
}

/// kv_get through the global handle, "" when unset or unavailable.
pub fn kv(key: &str) -> String {
    with(|c| kv_get(c, key)).ok().flatten().unwrap_or_default()
}

// ------------------------------------------------------------------- hosts

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Host {
    pub id: i64,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub user: String,
    pub keypath: String,
    pub platform: String,
    pub tags: String,
    pub created_ms: i64,
    pub last_used_ms: i64,
    pub use_count: i64,
}

impl Host {
    pub fn from_json(v: &Value) -> Result<Host, String> {
        let s = |k: &str| {
            v.get(k)
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .trim()
                .to_string()
        };
        let host = s("host");
        let user = s("user");
        if host.is_empty() || user.is_empty() {
            return Err("host and user are required".into());
        }
        let port = v.get("port").and_then(|p| p.as_u64()).unwrap_or(22);
        let port = if port == 0 || port > 65535 {
            22
        } else {
            port as u16
        };
        Ok(Host {
            id: v.get("id").and_then(|i| i.as_i64()).unwrap_or(0),
            name: s("name"),
            host,
            port,
            user,
            keypath: s("keypath"),
            platform: s("platform"),
            tags: s("tags"),
            created_ms: 0,
            last_used_ms: v.get("last_used_ms").and_then(|x| x.as_i64()).unwrap_or(0),
            use_count: v.get("use_count").and_then(|x| x.as_i64()).unwrap_or(0),
        })
    }

    pub fn to_json(&self) -> Value {
        json!({
            "id": self.id, "name": self.name, "host": self.host, "port": self.port,
            "user": self.user, "keypath": self.keypath, "platform": self.platform,
            "tags": self.tags, "created_ms": self.created_ms,
            "last_used_ms": self.last_used_ms, "use_count": self.use_count,
        })
    }

    /// Text indexed for search / embeddings.
    pub fn search_text(&self) -> String {
        format!(
            "{} {}@{}:{} {}",
            self.name, self.user, self.host, self.port, self.tags
        )
        .trim()
        .to_string()
    }
}

fn row_to_host(r: &rusqlite::Row) -> rusqlite::Result<Host> {
    Ok(Host {
        id: r.get(0)?,
        name: r.get(1)?,
        host: r.get(2)?,
        port: r.get::<_, i64>(3)? as u16,
        user: r.get(4)?,
        keypath: r.get(5)?,
        platform: r.get(6)?,
        tags: r.get(7)?,
        created_ms: r.get(8)?,
        last_used_ms: r.get(9)?,
        use_count: r.get(10)?,
    })
}

const HOST_COLS: &str =
    "id, name, host, port, user, keypath, platform, tags, created_ms, last_used_ms, use_count";

pub fn host_get(conn: &Connection, id: i64) -> Result<Option<Host>, String> {
    conn.query_row(
        &format!("SELECT {} FROM hosts WHERE id = ?1", HOST_COLS),
        params![id],
        row_to_host,
    )
    .optional()
    .map_err(sql_err)
}

pub fn host_find(
    conn: &Connection,
    user: &str,
    host: &str,
    port: u16,
) -> Result<Option<Host>, String> {
    conn.query_row(
        &format!(
            "SELECT {} FROM hosts WHERE user = ?1 AND host = ?2 AND port = ?3",
            HOST_COLS
        ),
        params![user, host, port as i64],
        row_to_host,
    )
    .optional()
    .map_err(sql_err)
}

pub fn host_list(conn: &Connection) -> Result<Vec<Host>, String> {
    let mut st = conn
        .prepare(&format!(
            "SELECT {} FROM hosts ORDER BY last_used_ms DESC, use_count DESC, id ASC",
            HOST_COLS
        ))
        .map_err(sql_err)?;
    let rows = st.query_map([], row_to_host).map_err(sql_err)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(sql_err)
}

/// Insert or update. Keyed by id when > 0, else by user@host:port. Returns id.
pub fn host_upsert(conn: &Connection, h: &Host) -> Result<i64, String> {
    let existing = if h.id > 0 {
        host_get(conn, h.id)?
    } else {
        host_find(conn, &h.user, &h.host, h.port)?
    };
    let now = now_ms() as i64;
    let id = match existing {
        Some(old) => {
            let name = if h.name.is_empty() {
                old.name.clone()
            } else {
                h.name.clone()
            };
            let last_used = h.last_used_ms.max(old.last_used_ms);
            let use_count = h.use_count.max(old.use_count);
            conn.execute(
                "UPDATE hosts SET name=?1, host=?2, port=?3, user=?4, keypath=?5, platform=?6,
                 tags=?7, last_used_ms=?8, use_count=?9 WHERE id=?10",
                params![
                    name,
                    h.host,
                    h.port as i64,
                    h.user,
                    h.keypath,
                    h.platform,
                    h.tags,
                    last_used,
                    use_count,
                    old.id
                ],
            )
            .map_err(|e| format!("host update: {}", e))?;
            old.id
        }
        None => {
            conn.execute(
                "INSERT INTO hosts(name, host, port, user, keypath, platform, tags, created_ms,
                 last_used_ms, use_count) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
                params![
                    h.name,
                    h.host,
                    h.port as i64,
                    h.user,
                    h.keypath,
                    h.platform,
                    h.tags,
                    now,
                    h.last_used_ms,
                    h.use_count
                ],
            )
            .map_err(|e| format!("host insert: {}", e))?;
            conn.last_insert_rowid()
        }
    };
    // Keep the FTS mirror in sync (rowid == hosts.id).
    if let Some(row) = host_get(conn, id)? {
        conn.execute("DELETE FROM hosts_fts WHERE rowid = ?1", params![id])
            .map_err(sql_err)?;
        conn.execute(
            "INSERT INTO hosts_fts(rowid, name, host, user, tags) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![id, row.name, row.host, row.user, row.tags],
        )
        .map_err(sql_err)?;
        conn.execute(
            "DELETE FROM embeddings WHERE kind = 'host' AND ref_id = ?1",
            params![id],
        )
        .map_err(sql_err)?;
    }
    crate::embed::invalidate_cache();
    Ok(id)
}

pub fn host_delete(conn: &Connection, id: i64) -> Result<bool, String> {
    let n = conn
        .execute("DELETE FROM hosts WHERE id = ?1", params![id])
        .map_err(sql_err)?;
    conn.execute("DELETE FROM hosts_fts WHERE rowid = ?1", params![id])
        .map_err(sql_err)?;
    conn.execute(
        "DELETE FROM embeddings WHERE kind = 'host' AND ref_id = ?1",
        params![id],
    )
    .map_err(sql_err)?;
    crate::embed::invalidate_cache();
    Ok(n > 0)
}

/// Mark a host as used now (from a session link).
pub fn host_touch(conn: &Connection, id: i64) -> Result<(), String> {
    conn.execute(
        "UPDATE hosts SET last_used_ms = ?1, use_count = use_count + 1 WHERE id = ?2",
        params![now_ms() as i64, id],
    )
    .map(|_| ())
    .map_err(sql_err)
}

/// Hosts by use_count then recency: [{id, name, host, user, port, use_count, last_used_ms}].
pub fn frequent_hosts(conn: &Connection, limit: usize) -> Result<Vec<Value>, String> {
    let mut list = host_list(conn)?;
    list.sort_by(|a, b| {
        b.use_count
            .cmp(&a.use_count)
            .then(b.last_used_ms.cmp(&a.last_used_ms))
    });
    Ok(list
        .into_iter()
        .take(limit)
        .map(|h| {
            json!({"id": h.id, "name": h.name, "host": h.host, "user": h.user, "port": h.port,
                   "use_count": h.use_count, "last_used_ms": h.last_used_ms})
        })
        .collect())
}

// ---------------------------------------------------------------- sessions

#[allow(clippy::too_many_arguments)]
pub fn session_start(
    conn: &Connection,
    slot: i32,
    host_id: i64,
    name: &str,
    host: &str,
    port: u16,
    user: &str,
    cols: u16,
    rows: u16,
) -> Result<i64, String> {
    conn.execute(
        "INSERT INTO sessions(slot, host_id, name, host, port, user, started_ms, cols, rows)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
        params![
            slot,
            host_id,
            name,
            host,
            port as i64,
            user,
            now_ms() as i64,
            cols,
            rows
        ],
    )
    .map_err(sql_err)?;
    Ok(conn.last_insert_rowid())
}

pub fn session_end(conn: &Connection, id: i64, end_state: i32) -> Result<(), String> {
    conn.execute(
        "UPDATE sessions SET ended_ms = ?1, end_state = ?2 WHERE id = ?3 AND ended_ms = 0",
        params![now_ms() as i64, end_state, id],
    )
    .map(|_| ())
    .map_err(sql_err)
}

pub fn session_set_host(conn: &Connection, id: i64, host_id: i64) -> Result<(), String> {
    conn.execute(
        "UPDATE sessions SET host_id = ?1 WHERE id = ?2",
        params![host_id, id],
    )
    .map_err(sql_err)?;
    conn.execute(
        "UPDATE commands SET host_id = ?1 WHERE session_id = ?2 AND host_id = 0",
        params![host_id, id],
    )
    .map(|_| ())
    .map_err(sql_err)
}

pub fn session_set_name(conn: &Connection, id: i64, name: &str) -> Result<(), String> {
    conn.execute(
        "UPDATE sessions SET name = ?1 WHERE id = ?2",
        params![name, id],
    )
    .map(|_| ())
    .map_err(sql_err)
}

// ------------------------------------------------------------------- stats

pub fn table_count(conn: &Connection, table: &str) -> i64 {
    conn.query_row(&format!("SELECT COUNT(*) FROM {}", table), [], |r| r.get(0))
        .unwrap_or(0)
}

pub fn db_size_bytes(conn: &Connection) -> i64 {
    conn.query_row(
        "SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size()",
        [],
        |r| r.get(0),
    )
    .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrations_are_idempotent_and_fts5_works() {
        let conn = open_memory().expect("mem db");
        assert_eq!(schema_version(&conn), 4);
        migrate(&conn).expect("second migrate");
        migrate(&conn).expect("third migrate");
        assert_eq!(schema_version(&conn), 4);
        assert_eq!(table_count(&conn, "migrations"), 4);
        assert_eq!(table_count(&conn, "notes"), 0);
        assert_eq!(table_count(&conn, "cmd_transitions"), 0);
        assert!(fts5_available(&conn));
        conn.execute(
            "INSERT INTO commands_fts(rowid, cmd) VALUES (1, 'git status')",
            [],
        )
        .expect("fts insert");
        let hit: i64 = conn
            .query_row(
                "SELECT rowid FROM commands_fts WHERE commands_fts MATCH 'status'",
                [],
                |r| r.get(0),
            )
            .expect("fts match");
        assert_eq!(hit, 1);
    }

    #[test]
    fn kv_roundtrip() {
        let conn = open_memory().expect("mem db");
        assert_eq!(kv_get(&conn, "x").expect("get"), None);
        kv_set(&conn, "x", "香港").expect("set");
        kv_set(&conn, "x", "銅鑼灣 안녕").expect("set again");
        assert_eq!(
            kv_get(&conn, "x").expect("get").as_deref(),
            Some("銅鑼灣 안녕")
        );
    }

    #[test]
    fn host_upsert_dedupes_on_user_host_port() {
        let conn = open_memory().expect("mem db");
        let a = Host {
            host: "dev.hk".into(),
            user: "lee".into(),
            port: 22,
            name: "dev".into(),
            ..Default::default()
        };
        let id = host_upsert(&conn, &a).expect("insert");
        let again = host_upsert(
            &conn,
            &Host {
                name: "".into(),
                tags: "prod".into(),
                ..a.clone()
            },
        )
        .expect("upsert");
        assert_eq!(id, again);
        let row = host_get(&conn, id).expect("get").expect("row");
        assert_eq!(row.name, "dev", "empty name keeps the old one");
        assert_eq!(row.tags, "prod");
        assert_eq!(host_list(&conn).expect("list").len(), 1);
        assert!(host_delete(&conn, id).expect("delete"));
        assert!(!host_delete(&conn, id).expect("delete again"));
    }
}
