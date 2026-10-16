//! Signing in to Xiaomi from a window (the Windows app): start the sign-in, wait for it to be confirmed,
//! list the robots on the account, and save the one chosen. The same steps as `vacuumd setup`, but in
//! small requests so a window can show them. Tokens stay here; the window only sees names and addresses.
use crate::audit;
use crate::cloud::{self, CloudDevice, CloudSession, LoginStart, QrLogin, XiaomiCloud};
use crate::config::{self, RobotConfig};
use crate::policy;
use crate::server::App;
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

#[derive(Default)]
pub struct Sign {
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    phase: Phase,
    task: Option<tokio::task::JoinHandle<()>>,
}

#[derive(Default)]
enum Phase {
    #[default]
    Idle,
    Waiting,
    Found(Vec<(CloudSession, CloudDevice)>),
    Failed(String),
}

/// Starts a sign-in: returns the QR picture (as a PNG data address) and Xiaomi's sign-in page.
/// The rest happens in the background; `status` reports it.
pub async fn start(sign: &Arc<Sign>) -> Result<Value, String> {
    let login = QrLogin::new();
    let begun = login.start().await.map_err(|e| e.to_string())?;
    let picture = login.qr_image(&begun).await.map_err(|e| e.to_string())?;
    let web_login_url = begun.web_login_url.clone();
    let sign_task = sign.clone();
    let handle = tokio::spawn(async move {
        let result = confirm_and_find(&login, &begun).await;
        let mut inner = sign_task.inner.lock().unwrap();
        // A sign-in that was cancelled or replaced doesn't write over the newer one.
        if matches!(inner.phase, Phase::Waiting) {
            inner.phase = match result {
                Ok(found) => Phase::Found(found),
                Err(message) => Phase::Failed(message),
            };
        }
    });
    let mut inner = sign.inner.lock().unwrap();
    if let Some(old) = inner.task.take() {
        old.abort();
    }
    inner.task = Some(handle);
    inner.phase = Phase::Waiting;
    Ok(json!({
        "qrImage": format!("data:image/png;base64,{}", B64.encode(picture)),
        "webLoginUrl": web_login_url,
    }))
}

async fn confirm_and_find(login: &QrLogin, begun: &LoginStart) -> Result<Vec<(CloudSession, CloudDevice)>, String> {
    let session = login.wait_for_confirmation(begun, "de").await.map_err(|e| e.to_string())?;
    let mut found = vec![];
    for (region, _) in cloud::REGIONS {
        let regional = CloudSession { server: region.to_string(), ..session.clone() };
        // A region that doesn't answer is skipped, as in `vacuumd setup`.
        if let Ok(devices) = XiaomiCloud::new(regional.clone()).devices().await {
            for device in devices.into_iter().filter(|d| d.is_vacuum()) {
                found.push((regional.clone(), device));
            }
        }
    }
    Ok(found)
}

/// What the window shows: `idle`, `waiting`, `found` (with the robots), or `failed` (with why).
pub fn status(sign: &Sign) -> Value {
    let inner = sign.inner.lock().unwrap();
    match &inner.phase {
        Phase::Idle => json!({"state": "idle", "devices": []}),
        Phase::Waiting => json!({"state": "waiting", "devices": []}),
        Phase::Failed(message) => json!({"state": "failed", "error": message, "devices": []}),
        Phase::Found(found) => json!({
            "state": "found",
            "devices": found.iter().map(|(region, device)| json!({
                "did": device.did,
                "name": device.name,
                "model": device.model,
                "supported": device.is_supported(),
                "localIp": device.local_ip,
                "region": region.server,
            })).collect::<Vec<_>>(),
        }),
    }
}

pub fn cancel(sign: &Sign) {
    let mut inner = sign.inner.lock().unwrap();
    if let Some(task) = inner.task.take() {
        task.abort();
    }
    inner.phase = Phase::Idle;
}

/// Saves the chosen robot and the sign-in, then starts the robot service with them.
/// `ip` is only needed when Xiaomi doesn't know the robot's address.
pub fn choose(sign: &Sign, app: &App, did: &str, ip: Option<&str>) -> Result<Value, String> {
    let (region, device) = {
        let inner = sign.inner.lock().unwrap();
        let Phase::Found(found) = &inner.phase else {
            return Err("Sign in to Xiaomi first.".into());
        };
        let (region, device) = found.iter().find(|(_, d)| d.did == did).ok_or("That robot isn't on this account.")?;
        (region.clone(), device.clone())
    };
    if !device.is_supported() {
        return Err(format!("This robot ({}) isn't supported yet.", device.model));
    }
    let address = ip.map(str::trim).filter(|s| !s.is_empty()).map(String::from).unwrap_or(device.local_ip.clone());
    if address.is_empty() {
        return Err("Xiaomi doesn't know this robot's address. Enter it (see your router's device list).".into());
    }
    let robot = RobotConfig { ip: address.clone(), token: device.token.clone(), did: device.did.clone() };
    policy::validate_robot(&robot)?;
    policy::validate_cloud(&region)?;
    config::save_robot(&robot).map_err(|e| e.to_string())?;
    config::save_cloud(&region).map_err(|e| e.to_string())?;
    audit::record(json!({"event": "settings-updated", "via": "sign-in", "robot": true, "cloud": true}));
    app.reload().map_err(|e| e.0)?;
    sign.inner.lock().unwrap().phase = Phase::Idle;
    Ok(json!({"ok": true, "name": device.name, "ip": address}))
}
