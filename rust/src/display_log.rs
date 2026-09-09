//! Append-only display preferences journal; contains no credentials.
use std::io::Write;
use std::path::Path;

pub fn append(path: &Path, fullscreen: bool, orientation: &str) -> Result<(), String> {
    if !matches!(orientation, "auto" | "portrait" | "landscape") {
        return Err("invalid orientation".into());
    }
    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path).map_err(|e| e.to_string())?;
    file.lock().map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))
            .map_err(|e| e.to_string())?;
    }
    let value = serde_json::json!({ "timestamp_ms": crate::session::now_ms(),
        "fullscreen": fullscreen, "orientation": orientation,
        "horizontal": orientation == "landscape" });
    writeln!(file, "{value}").map_err(|e| e.to_string())?;
    file.sync_data().map_err(|e| e.to_string())
}
#[cfg(test)]
mod tests {
    #[test]
    fn appends_valid_json_lines() {
        let path = std::env::temp_dir().join(format!(
            "cbo-display-test-{}-{}.jsonl",
            std::process::id(),
            crate::session::now_ms()
        ));
        super::append(&path, false, "landscape").unwrap();
        super::append(&path, true, "portrait").unwrap();
        let rows: Vec<serde_json::Value> = std::fs::read_to_string(&path)
            .unwrap()
            .lines()
            .map(|s| serde_json::from_str(s).unwrap())
            .collect();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["horizontal"], true);
        assert_eq!(rows[1]["fullscreen"], true);
        assert_eq!(rows[1]["orientation"], "portrait");
        assert!(super::append(&path, true, "invalid").is_err());
        std::fs::remove_file(path).unwrap();
    }
}
