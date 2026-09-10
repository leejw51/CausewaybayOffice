//! Embeddings for semantic search. Provider: OpenAI text-embedding-3-small
//! (xai has no embeddings endpoint as of 2026-09; anthropic has none) when
//! "OpenAI indexing" is enabled and a key is present; otherwise a local,
//! dependency-free hashed n-gram model (`LOCAL_MODEL`) so BM25 and the
//! vector pass always run together, offline too. Vectors are stored per
//! model; switching providers re-embeds in the background.
//! A background thread embeds pending rows in batches; query vectors are
//! computed synchronously and cached.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, Once};
use std::time::Duration;

use rusqlite::{params, Connection};
use serde_json::{json, Value};

use crate::db;
use crate::session::lock;

pub const MODEL: &str = "text-embedding-3-small";
pub const DIM: usize = 1536;
/// Offline fallback: signed feature hashing of words, word bigrams and
/// character trigrams, L2-normalised. Tolerant to typos, inflections and
/// CJK/Hangul without a tokenizer. Not a neural model: it finds near
/// spellings and shared fragments, not paraphrases.
pub const LOCAL_MODEL: &str = "local-ngram-v1";
pub const LOCAL_DIM: usize = 512;
/// Lowest local cosine that counts as a hit.
pub const LOCAL_MIN_SCORE: f32 = 0.08;
/// Rows per local batch (no network, so larger than `BATCH`).
pub const LOCAL_BATCH: usize = 512;
pub const ENDPOINT: &str = "https://api.openai.com/v1/embeddings";
pub const BATCH: usize = 64;
/// Longest text sent per row (chars).
pub const MAX_TEXT_CHARS: usize = 6000;
const WORKER_IDLE: Duration = Duration::from_secs(2);
const WORKER_BETWEEN_BATCHES: Duration = Duration::from_millis(1000);

#[derive(Clone, Debug)]
pub struct Entry {
    pub kind: String,
    pub ref_id: i64,
    pub model: String,
    pub vec: Vec<f32>,
}

static CACHE: Mutex<Option<Vec<Entry>>> = Mutex::new(None);
static QUERY_CACHE: Mutex<Option<HashMap<String, Vec<f32>>>> = Mutex::new(None);
static WORKER: Once = Once::new();
static PAUSED: AtomicBool = AtomicBool::new(false);

/// Test hook: point the provider at a local server.
static ENDPOINT_OVERRIDE: Mutex<Option<String>> = Mutex::new(None);

pub fn set_endpoint_override(url: Option<&str>) {
    *lock(&ENDPOINT_OVERRIDE) = url.map(str::to_string);
}

fn endpoint() -> String {
    lock(&ENDPOINT_OVERRIDE)
        .clone()
        .unwrap_or_else(|| ENDPOINT.to_string())
}

/// kv "apikey.openai", falling back to OPENAI_API_KEY. Takes the open
/// connection so it can be used inside `db::with` (the DB mutex is not
/// reentrant).
pub fn api_key_with(conn: &Connection) -> Option<String> {
    // A chat API key is not consent to upload terminal history.
    if db::kv_get(conn, "embed.enabled").ok().flatten().as_deref() != Some("1") {
        return None;
    }
    let kv = db::kv_get(conn, "apikey.openai")
        .ok()
        .flatten()
        .unwrap_or_default();
    if !kv.trim().is_empty() {
        return Some(kv.trim().to_string());
    }
    std::env::var("OPENAI_API_KEY")
        .ok()
        .map(|k| k.trim().to_string())
        .filter(|k| !k.is_empty())
}

/// Global-handle variant: never call while holding the DB lock.
pub fn api_key() -> Option<String> {
    db::with(|c| Ok(api_key_with(c))).ok().flatten()
}

pub fn available_with(conn: &Connection) -> bool {
    api_key_with(conn).is_some()
}

pub fn available() -> bool {
    api_key().is_some()
}

/// The model whose vectors searches and the worker use right now.
pub fn model_with(conn: &Connection) -> &'static str {
    if available_with(conn) {
        MODEL
    } else {
        LOCAL_MODEL
    }
}

pub fn model() -> &'static str {
    if available() {
        MODEL
    } else {
        LOCAL_MODEL
    }
}

// ---------------------------------------------------------------- local

fn fnv1a(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        h ^= *b as u64;
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    h
}

fn bump(v: &mut [f32], feature: &str, weight: f32) {
    let h = fnv1a(feature.as_bytes());
    let idx = (h % v.len() as u64) as usize;
    let sign = if (h >> 63) == 1 { -1.0 } else { 1.0 };
    v[idx] += sign * weight;
}

/// Local vector of a text (see `LOCAL_MODEL`). Empty text -> zero vector.
pub fn local_vec(text: &str) -> Vec<f32> {
    let mut v = vec![0.0f32; LOCAL_DIM];
    let lower = text.to_lowercase();
    let tokens: Vec<&str> = lower
        .split(|c: char| !c.is_alphanumeric())
        .filter(|t| !t.is_empty())
        .collect();
    for (i, tok) in tokens.iter().enumerate() {
        bump(&mut v, &format!("w:{}", tok), 1.0);
        if let Some(next) = tokens.get(i + 1) {
            bump(&mut v, &format!("b:{} {}", tok, next), 0.7);
        }
        let padded: Vec<char> = std::iter::once(' ')
            .chain(tok.chars())
            .chain(std::iter::once(' '))
            .collect();
        if padded.len() >= 3 {
            for win in padded.windows(3) {
                let tri: String = win.iter().collect();
                bump(&mut v, &format!("t:{}", tri), 0.5);
            }
        }
    }
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 0.0 {
        for x in v.iter_mut() {
            *x /= norm;
        }
    }
    v
}

/// Pause the background worker (tests that want deterministic pending counts).
pub fn set_paused(p: bool) {
    PAUSED.store(p, Ordering::SeqCst);
}

// ---------------------------------------------------------------- HTTP

pub fn embed_texts(key: &str, texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
    if texts.is_empty() {
        return Ok(Vec::new());
    }
    let inputs: Vec<String> = texts.iter().map(|t| clip(t, MAX_TEXT_CHARS)).collect();
    let agent = ureq::AgentBuilder::new()
        .redirects(0)
        .timeout_connect(Duration::from_secs(20))
        .timeout_read(Duration::from_secs(120))
        .build();
    let resp = agent
        .post(&endpoint())
        .set("Authorization", &format!("Bearer {}", key))
        .set("Content-Type", "application/json")
        .send_json(json!({"model": MODEL, "input": inputs}));
    let resp = match resp {
        Ok(r) => r,
        Err(ureq::Error::Status(code, r)) => {
            return Err(format!(
                "HTTP {}: {}",
                code,
                r.into_string().unwrap_or_default().trim()
            ));
        }
        Err(ureq::Error::Transport(t)) => return Err(format!("transport error: {}", t)),
    };
    let v: Value = resp.into_json().map_err(|e| format!("bad json: {}", e))?;
    let data = v
        .get("data")
        .and_then(|d| d.as_array())
        .ok_or_else(|| format!("no data in response: {}", clip(&v.to_string(), 300)))?;
    let mut out: Vec<(usize, Vec<f32>)> = Vec::with_capacity(data.len());
    for (i, item) in data.iter().enumerate() {
        let idx = item
            .get("index")
            .and_then(|x| x.as_u64())
            .map(|x| x as usize)
            .unwrap_or(i);
        let vec: Vec<f32> = item
            .get("embedding")
            .and_then(|e| e.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|x| x.as_f64())
                    .map(|x| x as f32)
                    .collect()
            })
            .unwrap_or_default();
        if vec.is_empty() {
            return Err("empty embedding in response".into());
        }
        out.push((idx, vec));
    }
    out.sort_by_key(|(i, _)| *i);
    if out.len() != texts.len() {
        return Err(format!(
            "expected {} embeddings, got {}",
            texts.len(),
            out.len()
        ));
    }
    if out.iter().enumerate().any(|(i, (idx, v))| {
        *idx != i || v.iter().any(|f| !f.is_finite()) || v.len() != out[0].1.len()
    }) {
        return Err("invalid embedding indices or dimensions".into());
    }
    Ok(out.into_iter().map(|(_, v)| v).collect())
}

fn clip(s: &str, max_chars: usize) -> String {
    if s.chars().count() <= max_chars {
        return s.to_string();
    }
    s.chars().take(max_chars).collect()
}

// --------------------------------------------------------------- store

pub fn to_blob(v: &[f32]) -> Vec<u8> {
    v.iter().flat_map(|f| f.to_le_bytes()).collect()
}

pub fn from_blob(b: &[u8]) -> Vec<f32> {
    b.chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect()
}

pub fn store(
    conn: &Connection,
    kind: &str,
    ref_id: i64,
    model: &str,
    vec: &[f32],
) -> Result<(), String> {
    conn.execute(
        "INSERT INTO embeddings(kind, ref_id, model, dim, vec) VALUES (?1,?2,?3,?4,?5)
         ON CONFLICT(kind, ref_id) DO UPDATE SET model=excluded.model, dim=excluded.dim, vec=excluded.vec",
        params![kind, ref_id, model, vec.len() as i64, to_blob(vec)],
    )
    .map_err(db::sql_err)?;
    if let Some(cache) = lock(&CACHE).as_mut() {
        cache.retain(|e| !(e.kind == kind && e.ref_id == ref_id));
        cache.push(Entry {
            kind: kind.to_string(),
            ref_id,
            model: model.to_string(),
            vec: vec.to_vec(),
        });
    }
    Ok(())
}

pub fn load_all(conn: &Connection) -> Result<Vec<Entry>, String> {
    let mut st = conn
        .prepare("SELECT kind, ref_id, model, vec FROM embeddings")
        .map_err(db::sql_err)?;
    let rows = st
        .query_map([], |r| {
            Ok(Entry {
                kind: r.get(0)?,
                ref_id: r.get(1)?,
                model: r.get(2)?,
                vec: from_blob(&r.get::<_, Vec<u8>>(3)?),
            })
        })
        .map_err(db::sql_err)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(db::sql_err)
}

/// All vectors, loaded lazily and kept in memory.
pub fn entries(conn: &Connection) -> Result<Vec<Entry>, String> {
    let mut g = lock(&CACHE);
    if g.is_none() {
        *g = Some(load_all(conn)?);
    }
    Ok(g.clone().unwrap_or_default())
}

pub fn invalidate_cache() {
    *lock(&CACHE) = None;
}

/// Drop the vector of a deleted row (store + cache).
pub fn remove(conn: &Connection, kind: &str, ref_id: i64) -> Result<(), String> {
    conn.execute(
        "DELETE FROM embeddings WHERE kind = ?1 AND ref_id = ?2",
        params![kind, ref_id],
    )
    .map_err(db::sql_err)?;
    if let Some(cache) = lock(&CACHE).as_mut() {
        cache.retain(|e| !(e.kind == kind && e.ref_id == ref_id));
    }
    Ok(())
}

// ------------------------------------------------------------- pending

/// Rows without a vector for the given model (?1). A row embedded by another
/// model counts as pending, so a provider switch re-embeds everything.
const PENDING_SQL: &str = "
SELECT 'command' AS kind, c.id AS ref_id, c.cmd AS text FROM commands c
  LEFT JOIN embeddings e ON e.kind = 'command' AND e.ref_id = c.id AND e.model = ?1 WHERE e.ref_id IS NULL
UNION ALL
SELECT 'ai', a.id, a.content FROM ai_messages a
  LEFT JOIN embeddings e ON e.kind = 'ai' AND e.ref_id = a.id AND e.model = ?1 WHERE e.ref_id IS NULL
UNION ALL
SELECT 'host', h.id, h.name || ' ' || h.user || '@' || h.host || ':' || h.port || ' ' || h.tags FROM hosts h
  LEFT JOIN embeddings e ON e.kind = 'host' AND e.ref_id = h.id AND e.model = ?1 WHERE e.ref_id IS NULL
UNION ALL
SELECT 'transcript', t.rowid, t.text FROM transcripts_fts t
  LEFT JOIN embeddings e ON e.kind = 'transcript' AND e.ref_id = t.rowid AND e.model = ?1 WHERE e.ref_id IS NULL
UNION ALL
SELECT 'note', n.id, n.text FROM notes n
  LEFT JOIN embeddings e ON e.kind = 'note' AND e.ref_id = n.id AND e.model = ?1 WHERE e.ref_id IS NULL
";

/// Rows still waiting for a vector of the current model.
pub fn pending_count(conn: &Connection) -> i64 {
    pending_count_for(conn, model_with(conn))
}

pub fn pending_count_for(conn: &Connection, model: &str) -> i64 {
    conn.query_row(
        &format!("SELECT COUNT(*) FROM ({})", PENDING_SQL),
        params![model],
        |r| r.get(0),
    )
    .unwrap_or(0)
}

pub fn pending_items(
    conn: &Connection,
    model: &str,
    limit: usize,
) -> Result<Vec<(String, i64, String)>, String> {
    let mut st = conn
        .prepare(&format!("{} LIMIT ?2", PENDING_SQL))
        .map_err(db::sql_err)?;
    let rows = st
        .query_map(params![model, limit as i64], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, String>(2)?,
            ))
        })
        .map_err(db::sql_err)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(db::sql_err)
}

/// Embed one batch of pending rows with the current model (OpenAI when
/// indexing is enabled, else local). Returns how many were stored.
pub fn run_once() -> Result<usize, String> {
    let key = api_key();
    let (model, batch) = match key {
        Some(_) => (MODEL, BATCH),
        None => (LOCAL_MODEL, LOCAL_BATCH),
    };
    let items = db::with(|c| pending_items(c, model, batch))?;
    if items.is_empty() {
        return Ok(0);
    }
    let texts: Vec<String> = items
        .iter()
        .map(|(_, _, t)| {
            if t.trim().is_empty() {
                "(empty)".to_string()
            } else {
                t.clone()
            }
        })
        .collect();
    let vecs = match &key {
        Some(k) => embed_texts(k, &texts)?,
        None => texts.iter().map(|t| local_vec(t)).collect(),
    };
    db::with(|c| {
        for ((kind, id, _), v) in items.iter().zip(vecs.iter()) {
            store(c, kind, *id, model, v)?;
        }
        Ok(items.len())
    })
}

/// Embed everything pending for the local model right now (no network).
/// Used after writes that should be searchable at once, and by tests.
pub fn run_local_all(conn: &Connection) -> Result<usize, String> {
    let mut n = 0;
    loop {
        let items = pending_items(conn, LOCAL_MODEL, LOCAL_BATCH)?;
        if items.is_empty() {
            return Ok(n);
        }
        for (kind, id, text) in &items {
            store(conn, kind, *id, LOCAL_MODEL, &local_vec(text))?;
        }
        n += items.len();
    }
}

/// Start the background embedder (idempotent).
pub fn start_worker() {
    WORKER.call_once(|| {
        let _ = std::thread::Builder::new()
            .name("cbo-embed".into())
            .spawn(|| loop {
                std::thread::sleep(WORKER_IDLE);
                if PAUSED.load(Ordering::SeqCst) {
                    continue;
                }
                match run_once() {
                    Ok(n) if n > 0 => std::thread::sleep(WORKER_BETWEEN_BATCHES),
                    Ok(_) => {}
                    // Back off on provider errors (bad key, rate limit).
                    Err(_) => std::thread::sleep(Duration::from_secs(30)),
                }
            });
    });
}

// --------------------------------------------------------------- query

/// Embedding of a query string with the current model (synchronous; the
/// remote one is cached by exact text). Safe inside `db::with`: the key is
/// read through `conn`.
pub fn query_vec_with(conn: &Connection, text: &str) -> Result<Vec<f32>, String> {
    match api_key_with(conn) {
        Some(key) => query_vec_keyed(&key, text),
        None => Ok(local_vec(text)),
    }
}

pub fn query_vec(text: &str) -> Result<Vec<f32>, String> {
    match api_key() {
        Some(key) => query_vec_keyed(&key, text),
        None => Ok(local_vec(text)),
    }
}

fn query_vec_keyed(key: &str, text: &str) -> Result<Vec<f32>, String> {
    let text = text.trim();
    if let Some(v) = lock(&QUERY_CACHE)
        .as_ref()
        .and_then(|m| m.get(text).cloned())
    {
        return Ok(v);
    }
    let v = embed_texts(key, &[text.to_string()])?
        .into_iter()
        .next()
        .ok_or("no embedding returned")?;
    let mut cache = lock(&QUERY_CACHE);
    let cache = cache.get_or_insert_with(HashMap::new);
    if cache.len() >= 256 {
        cache.clear();
    }
    cache.insert(text.to_string(), v.clone());
    Ok(v)
}

pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    if a.is_empty() || a.len() != b.len() {
        return 0.0;
    }
    let (mut dot, mut na, mut nb) = (0.0f32, 0.0f32, 0.0f32);
    for (x, y) in a.iter().zip(b) {
        dot += x * y;
        na += x * x;
        nb += y * y;
    }
    if na == 0.0 || nb == 0.0 {
        0.0
    } else {
        dot / (na.sqrt() * nb.sqrt())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn api_key_does_not_opt_in_to_history_upload() {
        let conn = db::open_memory().unwrap();
        db::kv_set(&conn, "apikey.openai", "test-private-key").unwrap();
        assert!(!available_with(&conn));
        db::kv_set(&conn, "embed.enabled", "1").unwrap();
        assert_eq!(api_key_with(&conn).as_deref(), Some("test-private-key"));
        db::kv_set(&conn, "embed.enabled", "0").unwrap();
        assert!(!available_with(&conn));
    }

    #[test]
    fn blob_roundtrip_and_cosine() {
        let v = vec![0.5f32, -1.25, 3.0];
        assert_eq!(from_blob(&to_blob(&v)), v);
        assert!((cosine(&v, &v) - 1.0).abs() < 1e-6);
        assert!((cosine(&[1.0, 0.0], &[0.0, 1.0])).abs() < 1e-6);
        assert_eq!(cosine(&[1.0], &[1.0, 2.0]), 0.0);
    }

    #[test]
    fn pending_tracks_missing_rows() {
        let conn = db::open_memory().expect("db");
        assert_eq!(pending_count(&conn), 0);
        conn.execute(
            "INSERT INTO commands(session_id, host_id, ts_ms, cmd) VALUES (1,0,1,'ls')",
            [],
        )
        .expect("cmd");
        conn.execute(
            "INSERT INTO transcripts_fts(session_id, text) VALUES (1, 'hello world')",
            [],
        )
        .expect("t");
        assert_eq!(pending_count(&conn), 2);
        assert_eq!(model_with(&conn), LOCAL_MODEL, "no key: local model");
        let items = pending_items(&conn, LOCAL_MODEL, 10).expect("items");
        assert_eq!(items.len(), 2);
        store(&conn, "command", 1, LOCAL_MODEL, &[0.1, 0.2]).expect("store");
        assert_eq!(pending_count(&conn), 1);
        assert_eq!(load_all(&conn).expect("load").len(), 1);
        assert_eq!(
            pending_count_for(&conn, MODEL),
            2,
            "a local vector does not satisfy the remote model"
        );
        assert_eq!(run_local_all(&conn).expect("local"), 1);
        assert_eq!(pending_count(&conn), 0);
        assert_eq!(load_all(&conn).expect("load")[0].model, LOCAL_MODEL);
    }

    #[test]
    fn local_vectors_rank_near_spellings() {
        let a = local_vec("restart nginx after certificate renewal");
        let b = local_vec("nginx restarted, certificates renewed");
        let c = local_vec("銅鑼灣 office wifi password");
        let d = local_vec("wifi password for the 銅鑼灣 office");
        assert_eq!(a.len(), LOCAL_DIM);
        assert!(
            (a.iter().map(|x| x * x).sum::<f32>() - 1.0).abs() < 1e-4,
            "unit length"
        );
        assert!(
            cosine(&a, &b) > cosine(&a, &c),
            "shared fragments score higher"
        );
        assert!(cosine(&c, &d) > 0.5);
        assert!(local_vec("").iter().all(|x| *x == 0.0));
        assert!((cosine(&local_vec("hello"), &local_vec("HELLO")) - 1.0).abs() < 1e-5);
    }
}
