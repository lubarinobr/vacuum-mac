//! Settings shared with the Mac app: the same files in the same folder
//! (macOS ~/Library/Application Support/Vacuum, Windows %APPDATA%\Vacuum, Linux ~/.local/share/Vacuum).
use crate::cloud::CloudSession;
use crate::spec::RoomPreference;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

#[derive(Clone, Serialize, Deserialize)]
pub struct RobotConfig {
    pub ip: String,
    pub token: String, // 32 hex characters
    pub did: String,
}

pub fn data_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("VACUUMD_DIR") {
        return PathBuf::from(dir);
    }
    dirs::data_dir().unwrap_or_else(|| PathBuf::from(".")).join("Vacuum")
}

fn load<T: serde::de::DeserializeOwned>(name: &str) -> Option<T> {
    serde_json::from_slice(&std::fs::read(data_dir().join(name)).ok()?).ok()
}

/// Writes a file only the current user can read.
pub fn write_private(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, bytes)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

pub fn robot() -> Option<RobotConfig> {
    load("robot.json")
}
pub fn cloud() -> Option<CloudSession> {
    load("cloud.json")
}
pub fn save_robot(robot: &RobotConfig) -> std::io::Result<()> {
    write_private(&data_dir().join("robot.json"), &serde_json::to_vec_pretty(robot).unwrap())
}
pub fn save_cloud(cloud: &CloudSession) -> std::io::Result<()> {
    write_private(&data_dir().join("cloud.json"), &serde_json::to_vec_pretty(cloud).unwrap())
}

pub fn hidden_rooms() -> HashSet<u32> {
    load::<Vec<u32>>("hidden-rooms.json").unwrap_or_default().into_iter().collect()
}

pub fn room_names() -> HashMap<u32, String> {
    load::<HashMap<String, String>>("room-names.json")
        .unwrap_or_default()
        .into_iter()
        .filter_map(|(k, v)| k.parse().ok().map(|id| (id, v)))
        .collect()
}

pub fn room_preferences() -> HashMap<u32, RoomPreference> {
    load::<HashMap<String, RoomPreference>>("room-preferences.json")
        .unwrap_or_default()
        .into_iter()
        .filter_map(|(k, v)| k.parse().ok().map(|id| (id, v)))
        .collect()
}

/// The bearer token clients must send. Created on first use, readable only by you.
pub fn api_token() -> std::io::Result<String> {
    let path = data_dir().join("daemon-token");
    if let Ok(existing) = std::fs::read_to_string(&path) {
        if existing.trim().len() >= 32 {
            return Ok(existing.trim().to_string());
        }
    }
    let token = hex::encode(crate::crypto::random_bytes::<32>());
    write_private(&path, token.as_bytes())?;
    Ok(token)
}

/// Where map pictures are saved: Pictures/Vacuum (or VACUUMD_MAP_DIR), falling back to the settings folder.
pub fn map_images_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("VACUUMD_MAP_DIR") {
        return PathBuf::from(dir);
    }
    dirs::picture_dir().map(|p| p.join("Vacuum")).unwrap_or_else(|| data_dir().join("maps"))
}

/// Keeps only the newest `keep` map pictures (names start with the date, so sorting by name sorts by age).
pub fn keep_newest_map_images(folder: &std::path::Path, keep: usize) {
    let Ok(entries) = std::fs::read_dir(folder) else { return };
    let mut files: Vec<PathBuf> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.file_name().and_then(|n| n.to_str()).map_or(false, |n| n.starts_with("vacuum-map-") && n.ends_with(".png")))
        .collect();
    files.sort();
    let excess = files.len().saturating_sub(keep);
    for old in files.into_iter().take(excess) {
        let _ = std::fs::remove_file(old);
    }
}

/// Keeps a record of every room edit (what was asked, rooms before and after) next to the other settings.
pub fn log_room_edit(entry: &serde_json::Value) {
    let path = data_dir().join("room-edits.json");
    let mut log: Vec<serde_json::Value> = std::fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
    log.push(entry.clone());
    let _ = write_private(&path, &serde_json::to_vec_pretty(&log).unwrap_or_default());
}
