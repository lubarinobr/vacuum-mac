//! The Windows app's shell. The window is plain HTML; this file only talks to the robot service (vacuumd)
//! on this PC, starts it when it isn't running, and adds the Windows glass backdrop (Mica or Acrylic).
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use base64::Engine;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::Duration;
#[cfg(target_os = "windows")]
use tauri::Manager;

/// The same port and token files the Mac app uses, so both apps share one robot service and one set of settings.
const PORT: u16 = 47231;

fn data_dir() -> PathBuf {
    std::env::var("VACUUMD_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| dirs::data_dir().unwrap_or_else(|| PathBuf::from(".")).join("Vacuum"))
}

fn client(timeout: u64) -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(timeout))
        .build()
        .map_err(|_| "Couldn't prepare the connection.".to_string())
}

/// Sends one request to the robot service with the app's token and returns its JSON answer.
async fn send(method: &str, path: &str, body: Option<Value>) -> Result<Value, String> {
    let token = std::fs::read_to_string(data_dir().join("daemon-token"))
        .map_err(|_| "The robot service hasn't started yet.".to_string())?;
    let url = format!("http://127.0.0.1:{PORT}{path}");
    let http = client(70)?;
    let mut request = if method == "GET" { http.get(&url) } else { http.post(&url) };
    request = request.bearer_auth(token.trim());
    if let Some(body) = body {
        request = request.json(&body);
    }
    let response = request.send().await.map_err(|_| "Can't reach the robot service.".to_string())?;
    let status = response.status();
    let text = response.text().await.map_err(|_| "The robot service sent an unreadable answer.".to_string())?;
    let value: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
    if status.is_success() {
        Ok(value)
    } else {
        Err(value["error"].as_str().map(String::from).unwrap_or_else(|| format!("The robot service said no ({status}).")))
    }
}

async fn healthy() -> bool {
    match client(2) {
        Ok(http) => http.get(format!("http://127.0.0.1:{PORT}/health")).send().await.map(|r| r.status().is_success()).unwrap_or(false),
        Err(_) => false,
    }
}

/// Used by the UI for every request: `path` is e.g. `/v1/tools/get_status`.
#[tauri::command]
async fn api(method: String, path: String, body: Option<Value>) -> Result<Value, String> {
    if !path.starts_with("/v1/") {
        return Err("That request isn't allowed.".into());
    }
    send(&method, &path, body).await
}

/// Starts the robot service (vacuumd) if it isn't running. It sits next to this program, or is found on PATH.
#[tauri::command]
async fn ensure_service() -> Result<bool, String> {
    if healthy().await {
        return Ok(true);
    }
    let name = if cfg!(windows) { "vacuumd.exe" } else { "vacuumd" };
    let beside = std::env::current_exe().ok().and_then(|exe| exe.parent().map(|dir| dir.join(name)));
    let program = match beside {
        Some(path) if path.exists() => path,
        _ => PathBuf::from(name),
    };
    let mut command = std::process::Command::new(program);
    command.arg("serve").stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW: no console window appears
    }
    if command.spawn().is_err() {
        return Err("The robot service (vacuumd) couldn't be started. Reinstall the app.".into());
    }
    for _ in 0..30 {
        tokio::time::sleep(Duration::from_millis(200)).await;
        if healthy().await {
            return Ok(true);
        }
    }
    Err("The robot service didn't start in time.".into())
}

/// Draws the map through the robot service. Returns the picture as a PNG data address, and how it was drawn
/// (`transform`), so the page can place furniture on it.
#[tauri::command]
async fn map_image(fresh: bool) -> Result<Value, String> {
    let result = send("POST", "/v1/tools/get_map_image", Some(json!({ "fresh": fresh }))).await?;
    let path = PathBuf::from(result["path"].as_str().unwrap_or_default());
    if path.extension().and_then(|e| e.to_str()) != Some("png") || !path.is_file() {
        return Err("The map picture isn't available yet.".into());
    }
    let bytes = std::fs::read(&path).map_err(|_| "Couldn't read the map picture.".to_string())?;
    Ok(json!({
        "image": format!("data:image/png;base64,{}", base64::engine::general_purpose::STANDARD.encode(bytes)),
        "transform": result["mapTransform"].clone(),
    }))
}

/// The files the Windows app keeps next to the robot service's settings. Room names, hidden rooms and
/// per-room settings are the same files the Mac app and vacuumd use; furniture is only ever kept here.
const STORES: [&str; 4] = ["room-names.json", "hidden-rooms.json", "room-preferences.json", "furniture.json"];

fn store_name(name: &str) -> Result<&str, String> {
    STORES.iter().copied().find(|known| *known == name).ok_or_else(|| "That file isn't allowed.".to_string())
}

#[tauri::command]
fn store_read(name: String) -> Result<Value, String> {
    let name = store_name(&name)?;
    match std::fs::read_to_string(data_dir().join(name)) {
        Ok(text) => Ok(serde_json::from_str(&text).unwrap_or(Value::Null)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Value::Null),
        Err(_) => Err("Couldn't read the saved settings.".into()),
    }
}

/// Writes the file all at once (a temporary file, then a rename), so a crash can't leave half of it.
#[tauri::command]
fn store_write(name: String, value: Value) -> Result<(), String> {
    let name = store_name(&name)?;
    let dir = data_dir();
    std::fs::create_dir_all(&dir).map_err(|_| "Couldn't save the settings.".to_string())?;
    let path = dir.join(name);
    let temporary = dir.join(format!("{name}.tmp"));
    let bytes = serde_json::to_vec(&value).map_err(|_| "Couldn't save the settings.".to_string())?;
    std::fs::write(&temporary, bytes).map_err(|_| "Couldn't save the settings.".to_string())?;
    std::fs::rename(&temporary, &path).map_err(|_| "Couldn't save the settings.".to_string())
}

/// Opens Xiaomi's own sign-in page in the browser. Only secure links to Xiaomi's domains are opened.
#[tauri::command]
fn open_external(url: String) -> Result<(), String> {
    let rest = url.strip_prefix("https://").ok_or("That link isn't allowed.")?;
    let host = rest.split(['/', '?', '#']).next().unwrap_or("").split(':').next().unwrap_or("");
    let trusted = host == "xiaomi.com" || host.ends_with(".xiaomi.com") || host == "mi.com" || host.ends_with(".mi.com");
    if !trusted || url.chars().any(|c| c.is_whitespace() || c.is_control() || c == '"') {
        return Err("That link isn't allowed.".into());
    }
    // Each program gets the link as one argument, so nothing in it is read as a command.
    let result = if cfg!(windows) {
        std::process::Command::new("rundll32").args(["url.dll,FileProtocolHandler", &url]).spawn()
    } else if cfg!(target_os = "macos") {
        std::process::Command::new("open").arg(&url).spawn()
    } else {
        std::process::Command::new("xdg-open").arg(&url).spawn()
    };
    result.map(|_| ()).map_err(|_| "Couldn't open the browser.".to_string())
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![api, ensure_service, map_image, store_read, store_write, open_external])
        .setup(|_app| {
            #[cfg(target_os = "windows")]
            {
                if let Some(window) = _app.get_webview_window("main") {
                    // Mica (Windows 11) is the native frosted backdrop; Acrylic is the fallback for older Windows.
                    if window_vibrancy::apply_mica(&window, None).is_err() {
                        let _ = window_vibrancy::apply_acrylic(&window, Some((20, 22, 28, 150)));
                    }
                }
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("the Vacuum window couldn't start");
}
