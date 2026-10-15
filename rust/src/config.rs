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

/// Creates a folder only the current user can open (and its parents as needed).
pub fn ensure_private_dir(path: &std::path::Path) -> std::io::Result<()> {
    std::fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    }
    #[cfg(windows)]
    restrict_to_current_user(path, true);
    Ok(())
}

/// Writes a file only the current user can read.
pub fn write_private(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        ensure_private_dir(parent)?;
    }
    std::fs::write(path, bytes)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    }
    #[cfg(windows)]
    restrict_to_current_user(path, false);
    Ok(())
}

/// Windows: remove inherited permissions and allow only the current user (the default profile permissions
/// are usually fine, but a file with a secret in it shouldn't depend on that).
#[cfg(windows)]
pub fn restrict_to_current_user(path: &std::path::Path, is_dir: bool) {
    let user = match (std::env::var("USERDOMAIN"), std::env::var("USERNAME")) {
        (Ok(domain), Ok(name)) => format!("{domain}\\{name}"),
        (_, Ok(name)) => name,
        _ => return,
    };
    let grant = if is_dir { format!("{user}:(OI)(CI)F") } else { format!("{user}:F") };
    let _ = std::process::Command::new("icacls").arg(path).args(["/inheritance:r", "/grant:r", &grant]).output();
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

fn token_in(dir: &std::path::Path, file: &str) -> std::io::Result<String> {
    let path = dir.join(file);
    if let Ok(existing) = std::fs::read_to_string(&path) {
        if existing.trim().len() >= 32 {
            return Ok(existing.trim().to_string());
        }
    }
    let token = hex::encode(crate::crypto::random_bytes::<32>());
    write_private(&path, token.as_bytes())?;
    Ok(token)
}

/// The Mac app's token: can use everything, including the raw robot channel and the settings.
/// Created on first use, readable only by you.
pub fn app_token() -> std::io::Result<String> {
    token_in(&data_dir(), "daemon-token")
}

/// The agents' token (used by `vacuumd mcp` and for URL-style MCP setups): can only use the tools.
/// If it leaks, nobody can send arbitrary robot commands or rewrite your settings with it.
pub fn mcp_token() -> std::io::Result<String> {
    token_in(&data_dir(), "mcp-token")
}

/// Everything vacuumd keeps that grants access: the Xiaomi sign-in, the robot's token and both access tokens.
pub const CREDENTIAL_FILES: [&str; 4] = ["cloud.json", "robot.json", "daemon-token", "mcp-token"];

/// Deletes the credential files in `dir`; returns the names that were there.
pub fn forget_credentials(dir: &std::path::Path) -> Vec<&'static str> {
    CREDENTIAL_FILES.iter().copied().filter(|name| std::fs::remove_file(dir.join(name)).is_ok()).collect()
}

/// Small preferences vacuumd keeps itself (settings.json).
#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Settings {
    /// "private" (default), "pictures", or a folder path.
    map_folder: Option<String>,
}

fn settings() -> Settings {
    load("settings.json").unwrap_or_default()
}

pub fn set_map_folder(value: &str) -> std::io::Result<()> {
    let mut current = settings();
    current.map_folder = if value == "private" { None } else { Some(value.to_string()) };
    write_private(&data_dir().join("settings.json"), &serde_json::to_vec_pretty(&current).unwrap())
}

/// Where map pictures go, and whether vacuumd owns that folder (then it is made private).
pub struct MapFolder {
    pub path: PathBuf,
    pub private: bool,
}

/// The folder for a setting: private (vacuumd's own folder, the default), pictures, or a path the user chose.
fn map_folder_for(setting: Option<&str>, data: &std::path::Path, pictures: Option<PathBuf>) -> MapFolder {
    let own = || MapFolder { path: data.join("maps"), private: true };
    match setting {
        None | Some("private") => own(),
        Some("pictures") => pictures.map(|p| MapFolder { path: p.join("Vacuum"), private: false }).unwrap_or_else(own),
        Some(path) => MapFolder { path: PathBuf::from(path), private: false },
    }
}

/// Where map pictures are saved. Private by default (a map shows the layout of a home, and folders like
/// Pictures are often backed up to the cloud); `vacuumd map-folder pictures` or a path changes it.
/// VACUUMD_MAP_DIR overrides everything (used by tests).
pub fn map_images_dir() -> MapFolder {
    if let Ok(dir) = std::env::var("VACUUMD_MAP_DIR") {
        return MapFolder { path: PathBuf::from(dir), private: false };
    }
    map_folder_for(settings().map_folder.as_deref(), &data_dir(), dirs::picture_dir())
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

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("vacuumd-config-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn secrets_are_written_to_a_private_folder_and_private_files() {
        let dir = temp("private").join("nested");
        let file = dir.join("secret.json");
        write_private(&file, b"{}").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600, "file");
            assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700, "folder");
        }
        #[cfg(windows)]
        {
            // Nobody but the current user (and no "Everyone" / "Users" group) may be on the list.
            let listing = String::from_utf8_lossy(&std::process::Command::new("icacls").arg(&file).output().unwrap().stdout).to_string();
            for group in ["Everyone", "BUILTIN\\Users", "Authenticated Users"] {
                assert!(!listing.contains(group), "{group} must not have access:\n{listing}");
            }
            assert!(listing.contains(&std::env::var("USERNAME").unwrap()), "the current user keeps access:\n{listing}");
        }
    }

    #[test]
    fn map_pictures_are_private_unless_the_user_chooses_a_folder() {
        let data = std::path::Path::new("/data");
        let pictures = Some(PathBuf::from("/home/me/Pictures"));
        let default = map_folder_for(None, data, pictures.clone());
        assert_eq!((default.path, default.private), (PathBuf::from("/data/maps"), true));
        let private = map_folder_for(Some("private"), data, pictures.clone());
        assert!(private.private);
        let chosen = map_folder_for(Some("pictures"), data, pictures);
        assert_eq!((chosen.path, chosen.private), (PathBuf::from("/home/me/Pictures/Vacuum"), false), "a folder the user picked is never re-permissioned");
        let custom = map_folder_for(Some("/tmp/my-maps"), data, None);
        assert_eq!((custom.path, custom.private), (PathBuf::from("/tmp/my-maps"), false));
        assert!(map_folder_for(Some("pictures"), data, None).private, "no Pictures folder: fall back to the private one");
    }

    #[test]
    fn the_two_tokens_are_different_long_and_stable() {
        let dir = temp("tokens");
        let (app, mcp) = (token_in(&dir, "daemon-token").unwrap(), token_in(&dir, "mcp-token").unwrap());
        assert_eq!((app.len(), mcp.len()), (64, 64));
        assert_ne!(app, mcp, "a leaked agent token must not be the app's token");
        assert_eq!(token_in(&dir, "daemon-token").unwrap(), app, "the same token is reused");
    }

    #[test]
    fn logout_deletes_credentials_and_nothing_else() {
        let dir = temp("logout");
        for name in CREDENTIAL_FILES {
            write_private(&dir.join(name), b"secret").unwrap();
        }
        for keep in ["room-names.json", "furniture.json", "audit.log"] {
            write_private(&dir.join(keep), b"mine").unwrap();
        }
        let mut gone = forget_credentials(&dir);
        gone.sort();
        assert_eq!(gone, ["cloud.json", "daemon-token", "mcp-token", "robot.json"]);
        for name in CREDENTIAL_FILES {
            assert!(!dir.join(name).exists(), "{name} must be gone");
        }
        for keep in ["room-names.json", "furniture.json", "audit.log"] {
            assert!(dir.join(keep).exists(), "{keep} must stay");
        }
        assert!(forget_credentials(&dir).is_empty(), "nothing left to delete the second time");
    }
}
