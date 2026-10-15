//! A record of what was asked of the robot, so you can see afterwards what an agent (or anything else
//! holding a token) did. One JSON object per line in audit.log, readable only by you, rotated when large.
//! It never contains tokens or the values written to the robot, only what was done.
use crate::config;
use serde_json::{json, Value};
use std::io::Write;
use std::path::Path;
use std::sync::Mutex;

static LOCK: Mutex<()> = Mutex::new(());
const MAX_BYTES: u64 = 1_000_000;
const KEEP_OLD_FILES: usize = 3;

pub fn record(mut entry: Value) {
    entry["time"] = json!(chrono::Local::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, false));
    record_at(&config::data_dir().join("audit.log"), &entry, MAX_BYTES);
}

/// Never fails the request it describes: a full disk must not stop the robot from being controlled.
pub fn record_at(path: &Path, entry: &Value, max_bytes: u64) {
    let _guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    if std::fs::metadata(path).map_or(false, |m| m.len() >= max_bytes) {
        rotate(path);
    }
    if !path.exists() {
        let _ = config::write_private(path, b"");
    }
    if let Ok(mut file) = std::fs::OpenOptions::new().append(true).open(path) {
        let _ = writeln!(file, "{}", clean(entry));
    }
}

fn rotate(path: &Path) {
    let numbered = |n: usize| path.with_file_name(format!("{}.{n}", path.file_name().unwrap().to_string_lossy()));
    let _ = std::fs::remove_file(numbered(KEEP_OLD_FILES));
    for n in (1..KEEP_OLD_FILES).rev() {
        let _ = std::fs::rename(numbered(n), numbered(n + 1));
    }
    let _ = std::fs::rename(path, numbered(1));
}

/// Removes anything that looks like a secret and shortens long text.
pub fn clean(value: &Value) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(k, v)| {
                    let secret = ["token", "ssecurity", "servicetoken", "password", "passwd", "authorization"].iter().any(|s| k.to_lowercase().contains(s));
                    (k.clone(), if secret { json!("***") } else { clean(v) })
                })
                .collect(),
        ),
        Value::Array(items) => Value::Array(items.iter().take(50).map(clean).collect()),
        Value::String(text) if text.chars().count() > 300 => json!(format!("{}…", text.chars().take(300).collect::<String>())),
        other => other.clone(),
    }
}

/// The newest `count` entries, oldest first.
pub fn recent(count: usize) -> Vec<Value> {
    let path = config::data_dir().join("audit.log");
    let mut lines: Vec<String> = vec![];
    for file in [path.with_file_name("audit.log.1"), path] {
        if let Ok(text) = std::fs::read_to_string(file) {
            lines.extend(text.lines().map(String::from));
        }
    }
    let skip = lines.len().saturating_sub(count);
    lines.into_iter().skip(skip).filter_map(|l| serde_json::from_str(&l).ok()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("vacuumd-audit-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn secrets_never_reach_the_log() {
        let cleaned = clean(&json!({"tool": "x", "token": "abc", "nested": {"serviceToken": "def", "Authorization": "Bearer z"}, "rooms": [1, 2]}));
        let text = cleaned.to_string();
        assert!(!text.contains("abc") && !text.contains("def") && !text.contains("Bearer"), "{text}");
        assert_eq!(cleaned["tool"], "x");
        assert_eq!(cleaned["rooms"], json!([1, 2]));
        assert_eq!(clean(&json!("x".repeat(1000))).as_str().unwrap().chars().count(), 301, "long text is cut");
    }

    #[test]
    fn entries_are_appended_one_per_line_in_a_private_file() {
        let path = temp("append").join("audit.log");
        record_at(&path, &json!({"tool": "go_home", "ok": true}), 1_000_000);
        record_at(&path, &json!({"tool": "locate", "ok": true}), 1_000_000);
        let lines: Vec<String> = std::fs::read_to_string(&path).unwrap().lines().map(String::from).collect();
        assert_eq!(lines.len(), 2);
        assert_eq!(serde_json::from_str::<Value>(&lines[1]).unwrap()["tool"], "locate");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        }
    }

    #[test]
    fn a_big_log_is_rotated_and_only_a_few_old_files_are_kept() {
        let dir = temp("rotate");
        let path = dir.join("audit.log");
        for i in 0..40 {
            record_at(&path, &json!({"n": i, "padding": "x".repeat(60)}), 500);
        }
        let mut files: Vec<String> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().to_string()).collect();
        files.sort();
        assert_eq!(files, ["audit.log", "audit.log.1", "audit.log.2", "audit.log.3"], "the oldest are dropped");
        let newest: Value = serde_json::from_str(std::fs::read_to_string(&path).unwrap().lines().last().unwrap()).unwrap();
        assert_eq!(newest["n"], 39, "the newest entry is in the live file");
    }
}
