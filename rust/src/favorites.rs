//! Favorites JSONL snapshot. Credentials are excluded by an explicit field allowlist.
use serde_json::{json, Value};
use std::io::Write;
use std::path::Path;

pub fn save(dir: &Path, text: &str) -> Result<(), String> {
    save_named(dir, "favorites", text)
}
pub fn save_named(dir: &Path, name: &str, text: &str) -> Result<(), String> {
    if text.len() > 8 * 1024 * 1024 {
        return Err("favorites payload too large".into());
    }
    let data: Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
    let hosts = data["hosts"].as_array().ok_or("hosts array required")?;
    if hosts.len() > 10000 {
        return Err("too many favorites".into());
    }
    let mut output = String::new();
    for h in hosts {
        crate::db::Host::from_json(h)?;
        let mut safe = serde_json::Map::new();
        for key in [
            "host",
            "user",
            "port",
            "keypath",
            "lastUsed",
            "firstSeen",
            "platform",
            "label",
            "name",
            "cwd",
        ] {
            if let Some(value) = h.get(key) {
                safe.insert(key.into(), value.clone());
            }
        }
        if name == "favorites" {
            safe.insert("favorite".into(), json!(true));
        } else {
            safe.insert("connected".into(), json!(true));
        }
        output.push_str(&Value::Object(safe).to_string());
        output.push('\n');
    }
    let lock = private_file(&dir.join(format!("{name}.lock")), false)?;
    lock.lock().map_err(|e| e.to_string())?;
    let temp = dir.join(format!("{name}.jsonl.tmp"));
    let mut file = private_file(&temp, true)?;
    file.write_all(output.as_bytes())
        .map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    std::fs::rename(&temp, dir.join(format!("{name}.jsonl"))).map_err(|e| e.to_string())
}
pub(crate) fn private_file(path: &Path, truncate: bool) -> Result<std::fs::File, String> {
    let mut options = std::fs::OpenOptions::new();
    options.create(true).write(true).truncate(truncate);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options.open(path).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))
            .map_err(|e| e.to_string())?;
    }
    Ok(file)
}
pub fn load(dir: &Path) -> Result<Option<String>, String> {
    load_named(dir, "favorites")
}
pub fn load_named(dir: &Path, name: &str) -> Result<Option<String>, String> {
    let path = dir.join(format!("{name}.jsonl"));
    if !path.exists() {
        return Ok(None);
    }
    if std::fs::metadata(&path).map_err(|e| e.to_string())?.len() > 8 * 1024 * 1024 {
        return Err("favorites file too large".into());
    }
    let raw = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    let hosts = raw
        .lines()
        .filter(|s| !s.trim().is_empty())
        .map(serde_json::from_str::<Value>)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;
    Ok(Some(json!({"hosts":hosts}).to_string()))
}
#[cfg(test)]
mod tests {
    #[test]
    fn jsonl_roundtrip_updates_removes_and_excludes_passwords() {
        let dir = std::env::temp_dir().join(format!(
            "cbo-favorites-{}-{}",
            std::process::id(),
            crate::session::now_ms()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(super::load(&dir).unwrap(), None);
        super::save(&dir,r#"{"hosts":[{"host":"localhost","user":"u","port":22,"password":"never-save","label":"香港","platform":3}]}"#).unwrap();
        let text = std::fs::read_to_string(dir.join("favorites.jsonl")).unwrap();
        assert_eq!(text.lines().count(), 1);
        assert!(!text.contains("password"));
        assert!(super::load(&dir).unwrap().unwrap().contains("香港"));
        // sessions keep the remote working directory; secrets still never land
        super::save_named(&dir, "sessions", r#"{"hosts":[{"host":"localhost","user":"u","port":22,"name":"mary-1","cwd":"/srv/app","password":"x"}]}"#).unwrap();
        let text = std::fs::read_to_string(dir.join("sessions.jsonl")).unwrap();
        assert!(text.contains(r#""cwd":"/srv/app""#) && text.contains(r#""connected":true"#));
        assert!(!text.contains("password"));
        super::save(&dir, r#"{"hosts":[]}"#).unwrap();
        assert_eq!(super::load(&dir).unwrap().unwrap(), r#"{"hosts":[]}"#);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
