//! Generic private JSONL records under the data directory: one JSON object
//! per line, file mode 0600, written through a temp file and a rename. Used
//! for the API keys (`apikeys.jsonl`) and the AI tool registry
//! (`tools.jsonl`). The favorites/sessions snapshots keep their own module
//! because they filter fields.
use serde_json::{json, Value};
use std::io::Write;
use std::path::Path;

const MAX_BYTES: usize = 8 * 1024 * 1024;
const MAX_ROWS: usize = 10_000;
const RESERVED: [&str; 3] = ["favorites", "sessions", "display"];

/// A store name: lowercase ascii, digits and underscores, not a snapshot
/// that has its own writer.
pub fn valid_name(name: &str) -> bool {
    let ok = !name.is_empty()
        && name.len() <= 32
        && name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
        && name.as_bytes()[0].is_ascii_lowercase();
    ok && !RESERVED.contains(&name)
}

fn check_name(name: &str) -> Result<(), String> {
    if valid_name(name) {
        Ok(())
    } else {
        Err(format!("invalid store name '{}'", name))
    }
}

/// Replace `<name>.jsonl` with the objects of `{"rows":[...]}`.
pub fn save(dir: &Path, name: &str, text: &str) -> Result<(), String> {
    check_name(name)?;
    if text.len() > MAX_BYTES {
        return Err("payload too large".into());
    }
    let data: Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
    let rows = data["rows"].as_array().ok_or("rows array required")?;
    if rows.len() > MAX_ROWS {
        return Err("too many rows".into());
    }
    let mut output = String::new();
    for row in rows {
        if !row.is_object() {
            return Err("every row must be a JSON object".into());
        }
        output.push_str(&row.to_string());
        output.push('\n');
    }
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let lock = crate::favorites::private_file(&dir.join(format!("{name}.lock")), false)?;
    lock.lock().map_err(|e| e.to_string())?;
    let temp = dir.join(format!("{name}.jsonl.tmp"));
    let mut file = crate::favorites::private_file(&temp, true)?;
    file.write_all(output.as_bytes())
        .map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    std::fs::rename(&temp, dir.join(format!("{name}.jsonl"))).map_err(|e| e.to_string())
}

/// `{"rows":[...]}` from `<name>.jsonl`, `None` when the file does not exist.
/// Blank lines are skipped; a corrupt line is an error, never silently dropped.
pub fn load(dir: &Path, name: &str) -> Result<Option<String>, String> {
    check_name(name)?;
    let path = dir.join(format!("{name}.jsonl"));
    if !path.exists() {
        return Ok(None);
    }
    if std::fs::metadata(&path).map_err(|e| e.to_string())?.len() > MAX_BYTES as u64 {
        return Err("store file too large".into());
    }
    let raw = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    let rows = raw
        .lines()
        .filter(|s| !s.trim().is_empty())
        .map(serde_json::from_str::<Value>)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;
    Ok(Some(json!({"rows": rows}).to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_checked() {
        assert!(valid_name("apikeys"));
        assert!(valid_name("tools_v2"));
        assert!(!valid_name(""));
        assert!(!valid_name("Tools"));
        assert!(!valid_name("../etc"));
        assert!(!valid_name("favorites"));
        assert!(!valid_name("1abc"));
    }

    #[test]
    fn jsonl_roundtrip_is_private_and_atomic() {
        let dir = std::env::temp_dir().join(format!(
            "cbo-store-{}-{}",
            std::process::id(),
            crate::session::now_ms()
        ));
        assert_eq!(load(&dir, "apikeys").unwrap(), None);
        save(
            &dir,
            "apikeys",
            r#"{"rows":[{"provider":"openai","key":"sk-香港"},{"provider":"xai","key":""}]}"#,
        )
        .unwrap();
        let text = std::fs::read_to_string(dir.join("apikeys.jsonl")).unwrap();
        assert_eq!(text.lines().count(), 2);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(dir.join("apikeys.jsonl"))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        let back: Value = serde_json::from_str(&load(&dir, "apikeys").unwrap().unwrap()).unwrap();
        assert_eq!(back["rows"][0]["key"], "sk-香港");
        assert!(save(&dir, "apikeys", r#"{"rows":[1]}"#).is_err());
        assert!(save(&dir, "apikeys", r#"{"nope":[]}"#).is_err());
        // a failed save leaves the previous file intact
        let back: Value = serde_json::from_str(&load(&dir, "apikeys").unwrap().unwrap()).unwrap();
        assert_eq!(back["rows"].as_array().map(|r| r.len()), Some(2));
        save(&dir, "apikeys", r#"{"rows":[]}"#).unwrap();
        assert_eq!(load(&dir, "apikeys").unwrap().unwrap(), r#"{"rows":[]}"#);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
