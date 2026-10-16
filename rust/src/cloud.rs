//! Xiaomi cloud, used to find the robot's token (setup) and to download map files.
//! Only talks to account.xiaomi.com, sts.api.io.mi.com, <server>.api.io.mi.com and the map file URL the cloud returns.
//! Request signing follows PiotrMachowski/Xiaomi-cloud-tokens-extractor.
use crate::crypto;
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{json, Value};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

fn string_or_number<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    match Value::deserialize(d)? {
        Value::String(s) => Ok(s),
        Value::Number(n) => Ok(n.to_string()),
        _ => Err(serde::de::Error::custom("expected a string or number")),
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloudSession {
    pub server: String,
    #[serde(deserialize_with = "string_or_number")]
    pub user_id: String,
    pub ssecurity: String,
    pub service_token: String,
    pub agent: String,
}

#[derive(Debug)]
pub enum CloudError {
    Http(u16),
    LoginExpired,
    Unexpected(String),
    Network(String),
}

impl std::fmt::Display for CloudError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Http(code) => write!(f, "Xiaomi's server answered with HTTP {code}."),
            Self::LoginExpired => write!(f, "Your Xiaomi sign-in expired. Run `vacuumd setup` again."),
            Self::Unexpected(m) => write!(f, "Xiaomi sent an unexpected reply: {m}"),
            Self::Network(m) => write!(f, "Couldn't reach Xiaomi: {m}"),
        }
    }
}

impl From<reqwest::Error> for CloudError {
    fn from(e: reqwest::Error) -> Self {
        Self::Network(e.to_string())
    }
}

pub mod signing {
    use super::*;

    pub fn signed_nonce(ssecurity: &str, nonce: &str) -> String {
        let data = [B64.decode(ssecurity).unwrap_or_default(), B64.decode(nonce).unwrap_or_default()].concat();
        B64.encode(crypto::sha256(&data))
    }

    pub fn signature(method: &str, path: &str, params: &[(String, String)], signed_nonce: &str) -> String {
        let mut parts = vec![method.to_string(), path.to_string()];
        parts.extend(params.iter().map(|(k, v)| format!("{k}={v}")));
        parts.push(signed_nonce.to_string());
        B64.encode(crypto::sha1(parts.join("&").as_bytes()))
    }

    pub fn rc4(signed_nonce: &str, data: &[u8]) -> Vec<u8> {
        crypto::rc4_drop1024(&B64.decode(signed_nonce).unwrap_or_default(), data)
    }

    /// Builds the encrypted, signed form fields for one API call.
    pub fn fields(path: &str, data: &str, ssecurity: &str, nonce: &str) -> Vec<(String, String)> {
        let signed = signed_nonce(ssecurity, nonce);
        let mut params = vec![("data".to_string(), data.to_string())];
        let hash = signature("POST", path, &params, &signed);
        params.push(("rc4_hash__".to_string(), hash));
        let mut params: Vec<(String, String)> = params.into_iter().map(|(k, v)| (k, B64.encode(rc4(&signed, v.as_bytes())))).collect();
        let sig = signature("POST", path, &params, &signed);
        params.push(("signature".to_string(), sig));
        params.push(("ssecurity".to_string(), ssecurity.to_string()));
        params.push(("_nonce".to_string(), nonce.to_string()));
        params
    }

    pub fn new_nonce() -> String {
        let mut bytes = crypto::random_bytes::<8>().to_vec();
        let minutes = (SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs() / 60) as u32;
        bytes.extend_from_slice(&minutes.to_be_bytes());
        B64.encode(bytes)
    }
}

pub fn url_encode(value: &str) -> String {
    value
        .bytes()
        .map(|b| if b.is_ascii_alphanumeric() || b"-._~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") })
        .collect()
}

fn form_encode(value: &str) -> String {
    url_encode(value)
}

pub struct XiaomiCloud {
    pub session: CloudSession,
    http: reqwest::Client,
}

impl XiaomiCloud {
    pub fn new(session: CloudSession) -> Self {
        let http = reqwest::Client::builder().timeout(Duration::from_secs(15)).build().expect("http client");
        Self { session, http }
    }

    fn base_url(&self) -> String {
        let prefix = if self.session.server == "cn" { String::new() } else { format!("{}.", self.session.server) };
        format!("https://{prefix}api.io.mi.com/app")
    }

    pub async fn call(&self, endpoint: &str, payload: &Value) -> Result<Value, CloudError> {
        let path = format!("/{endpoint}");
        let nonce = signing::new_nonce();
        // sorted keys, like the Swift client, so signatures match what Xiaomi expects
        let data = serde_json::to_string(&sort_keys(payload)).unwrap();
        let fields = signing::fields(&path, &data, &self.session.ssecurity, &nonce);
        let body = fields.iter().map(|(k, v)| format!("{k}={}", form_encode(v))).collect::<Vec<_>>().join("&");
        let cookie = format!(
            "userId={}; serviceToken={}; yetAnotherServiceToken={}; locale=en_GB; channel=MI_APP_STORE",
            self.session.user_id, self.session.service_token, self.session.service_token
        );
        let response = self
            .http
            .post(format!("{}/{endpoint}", self.base_url()))
            .header("Content-Type", "application/x-www-form-urlencoded")
            .header("User-Agent", &self.session.agent)
            .header("Accept-Encoding", "identity")
            .header("x-xiaomi-protocal-flag-cli", "PROTOCAL-HTTP2")
            .header("MIOT-ENCRYPT-ALGORITHM", "ENCRYPT-RC4")
            .header("Cookie", cookie)
            .body(body)
            .send()
            .await?;
        let status = response.status().as_u16();
        if status == 401 {
            return Err(CloudError::LoginExpired);
        }
        if status != 200 {
            return Err(CloudError::Http(status));
        }
        let text = response.text().await?;
        let encrypted = B64.decode(text.trim()).map_err(|_| CloudError::Unexpected(text.chars().take(200).collect()))?;
        let signed = signing::signed_nonce(&self.session.ssecurity, &nonce);
        serde_json::from_slice(&signing::rc4(&signed, &encrypted)).map_err(|_| CloudError::Unexpected("not a JSON object".into()))
    }

    /// Signed download link for a map file the robot uploaded.
    pub async fn map_file_url(&self, object_name: &str) -> Result<String, CloudError> {
        let reply = self.call("v2/home/get_interim_file_url", &json!({"obj_name": object_name})).await?;
        match reply["result"]["url"].as_str() {
            Some(url) => Ok(url.to_string()),
            None if reply["code"].as_i64() == Some(3) => Err(CloudError::LoginExpired),
            None => Err(CloudError::Unexpected(reply.to_string())),
        }
    }

    /// Name of the map file the robot uploaded most recently (property 6.3 history in the cloud).
    pub async fn last_map_object_name(&self, did: &str) -> Result<Option<String>, CloudError> {
        let reply = self
            .call(
                "user/get_user_device_data",
                &json!({"uid": self.session.user_id, "did": did, "key": "6.3", "type": "prop", "limit": 1, "time_start": 0, "time_end": 9_999_999_999u64}),
            )
            .await?;
        let Some(value) = reply["result"][0]["value"].as_str() else { return Ok(None) };
        if let Ok(list) = serde_json::from_str::<Vec<String>>(value) {
            if let Some(first) = list.into_iter().next() {
                return Ok(Some(first));
            }
        }
        Ok(if value.is_empty() { None } else { Some(value.to_string()) })
    }

    pub async fn download(&self, url: &str) -> Result<String, CloudError> {
        let response = self.http.get(url).send().await?;
        if response.status().as_u16() != 200 {
            return Err(CloudError::Http(response.status().as_u16()));
        }
        Ok(response.text().await?)
    }
}

fn sort_keys(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut keys: Vec<_> = map.keys().collect();
            keys.sort();
            Value::Object(keys.into_iter().map(|k| (k.clone(), sort_keys(&map[k]))).collect())
        }
        Value::Array(items) => Value::Array(items.iter().map(sort_keys).collect()),
        other => other.clone(),
    }
}

// MARK: - Devices

pub const REGIONS: [(&str, &str); 8] = [
    ("de", "Europe"), ("us", "United States"), ("sg", "Singapore / Southeast Asia"), ("i2", "India (i2)"),
    ("ru", "Russia"), ("cn", "China mainland"), ("tw", "Taiwan"), ("in", "India"),
];

/// The only model supported: Xiaomi Robot Vacuum X20+.
pub const SUPPORTED_MODEL: &str = "xiaomi.vacuum.c102gl";

#[derive(Clone, Debug)]
pub struct CloudDevice {
    pub did: String,
    pub name: String,
    pub model: String,
    pub local_ip: String,
    pub token: String,
}

impl CloudDevice {
    pub fn is_supported(&self) -> bool {
        self.model == SUPPORTED_MODEL
    }
    pub fn is_vacuum(&self) -> bool {
        self.model.contains(".vacuum.")
    }
}

impl XiaomiCloud {
    /// All devices on the account (own homes and homes shared with it) on this session's server.
    pub async fn devices(&self) -> Result<Vec<CloudDevice>, CloudError> {
        let user_id: Value = self.session.user_id.parse::<i64>().map(Value::from).unwrap_or_else(|_| Value::from(self.session.user_id.clone()));
        let mut homes: Vec<(Value, Value)> = vec![];
        let reply = self
            .call("v2/homeroom/gethome", &json!({"fg": true, "fetch_share": true, "fetch_share_dev": true, "limit": 300, "app_ver": 7}))
            .await?;
        for home in reply["result"]["homelist"].as_array().into_iter().flatten() {
            if !home["id"].is_null() {
                homes.push((home["id"].clone(), user_id.clone()));
            }
        }
        let shared = self.call("v2/user/get_device_cnt", &json!({"fetch_own": true, "fetch_share": true})).await?;
        for home in shared["result"]["share"]["share_family"].as_array().into_iter().flatten() {
            if !home["home_id"].is_null() && !home["home_owner"].is_null() {
                homes.push((home["home_id"].clone(), home["home_owner"].clone()));
            }
        }
        let mut devices = vec![];
        for (id, owner) in homes {
            let reply = self
                .call(
                    "v2/home/home_device_list",
                    &json!({"home_owner": owner, "home_id": id, "limit": 200, "get_split_device": true, "support_smart_home": true}),
                )
                .await?;
            for info in reply["result"]["device_info"].as_array().into_iter().flatten() {
                let text = |key: &str| info[key].as_str().unwrap_or("").to_string();
                let Some(did) = info["did"].as_str().map(String::from).or_else(|| info["did"].as_i64().map(|n| n.to_string())) else { continue };
                devices.push(CloudDevice {
                    did,
                    name: info["name"].as_str().unwrap_or("Device").to_string(),
                    model: text("model"),
                    local_ip: text("localip"),
                    token: text("token"),
                });
            }
        }
        Ok(devices)
    }
}

// MARK: - Sign-in

/// Sign-in on Xiaomi's website (or by QR code): no password is typed into this program.
pub struct QrLogin {
    http: reqwest::Client,
    pub agent: String,
}

pub struct LoginStart {
    pub qr_image_url: String,
    /// Xiaomi's own sign-in page for this session; signing in there confirms it.
    pub web_login_url: Option<String>,
    pub poll_url: String,
    pub timeout: Duration,
}

impl QrLogin {
    pub fn new() -> Self {
        let letters = |from: u8, to: u8, n: usize| -> String { (0..n).map(|_| (from + rand::random::<u8>() % (to - from + 1)) as char).collect() };
        let agent = format!("{}-{} APP/com.xiaomi.mihome APPV/10.5.201", letters(97, 122, 18), letters(65, 69, 13));
        // 70 s so the 60 s wait for confirmation can finish; no redirects so the token cookie can be read.
        let http = reqwest::Client::builder()
            .user_agent(agent.clone())
            .timeout(Duration::from_secs(70))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("http client");
        Self { http, agent }
    }

    pub async fn start(&self) -> Result<LoginStart, CloudError> {
        let now_ms = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis();
        let query = [
            ("_qrsize", "480".to_string()),
            ("qs", "%3Fsid%3Dxiaomiio%26_json%3Dtrue".to_string()),
            ("callback", "https://sts.api.io.mi.com/sts".to_string()),
            ("_hasLogo", "false".to_string()),
            ("sid", "xiaomiio".to_string()),
            ("serviceParam", String::new()),
            ("_locale", "en_GB".to_string()),
            ("_dc", now_ms.to_string()),
        ];
        // Encoded like Python's urlencode: "qs" is already percent-encoded and gets encoded again.
        let query = query.iter().map(|(k, v)| format!("{k}={}", url_encode(v))).collect::<Vec<_>>().join("&");
        let json = self.get_json(&format!("https://account.xiaomi.com/longPolling/loginUrl?{query}")).await?;
        let (Some(qr), Some(lp)) = (json["qr"].as_str(), json["lp"].as_str()) else {
            return Err(CloudError::Unexpected(json.to_string()));
        };
        Ok(LoginStart {
            qr_image_url: qr.to_string(),
            web_login_url: json["loginUrl"].as_str().map(String::from),
            poll_url: lp.to_string(),
            timeout: Duration::from_secs_f64(json["timeout"].as_f64().unwrap_or(300.0)),
        })
    }

    /// Waits until the sign-in is confirmed, then returns the session (for the given server).
    pub async fn wait_for_confirmation(&self, start: &LoginStart, server: &str) -> Result<CloudSession, CloudError> {
        let deadline = std::time::Instant::now() + start.timeout;
        let mut refusals = 0;
        while std::time::Instant::now() < deadline {
            // Xiaomi answers the waiting connection once, when sign-in is confirmed. Keep it open long enough.
            let body = match self.http.get(&start.poll_url).timeout(Duration::from_secs(60)).send().await {
                Ok(response) => {
                    let status = response.status().as_u16();
                    if status != 200 {
                        refusals += 1;
                        if refusals >= 3 {
                            return Err(CloudError::Unexpected(format!("Xiaomi refused the sign-in (HTTP {status}). It may have expired: try again.")));
                        }
                        tokio::time::sleep(Duration::from_secs(2)).await; // never hammer Xiaomi's servers
                        continue;
                    }
                    response.text().await?
                }
                Err(_) => {
                    tokio::time::sleep(Duration::from_secs(1)).await;
                    continue;
                }
            };
            let json = parse_start_json(&body)?;
            let (Some(ssecurity), Some(location)) = (json["ssecurity"].as_str(), json["location"].as_str()) else {
                return Err(CloudError::Unexpected(json.to_string()));
            };
            let user_id = json["userId"].as_i64().map(|n| n.to_string()).or_else(|| json["userId"].as_str().map(String::from)).unwrap_or_default();
            let response = self.http.get(location).send().await?;
            let token = response
                .headers()
                .get_all(reqwest::header::SET_COOKIE)
                .iter()
                .filter_map(|v| v.to_str().ok())
                .find_map(|cookie| cookie.strip_prefix("serviceToken=").map(|rest| rest.split(';').next().unwrap_or("").to_string()))
                .ok_or_else(|| CloudError::Unexpected("no service token".into()))?;
            return Ok(CloudSession { server: server.to_string(), user_id, ssecurity: ssecurity.to_string(), service_token: token, agent: self.agent.clone() });
        }
        Err(CloudError::Unexpected("The sign-in expired".into()))
    }

    /// The QR code picture for this sign-in (PNG), so a window can show it without contacting Xiaomi itself.
    pub async fn qr_image(&self, start: &LoginStart) -> Result<Vec<u8>, CloudError> {
        Ok(self.http.get(&start.qr_image_url).send().await?.bytes().await?.to_vec())
    }

    async fn get_json(&self, url: &str) -> Result<Value, CloudError> {
        parse_start_json(&self.http.get(url).send().await?.text().await?)
    }
}

fn parse_start_json(body: &str) -> Result<Value, CloudError> {
    let text = body.replace("&&&START&&&", "");
    serde_json::from_str(&text).map_err(|_| CloudError::Unexpected(text.chars().take(200).collect()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rc4_roundtrips() {
        let key = b"a key";
        let data = b"hello xiaomi";
        assert_eq!(crypto::rc4_drop1024(key, &crypto::rc4_drop1024(key, data)), data);
    }

    #[test]
    fn signed_requests_have_every_field() {
        let ssecurity = B64.encode([7u8; 16]);
        let nonce = signing::new_nonce();
        let names: Vec<String> = signing::fields("/v2/x", "{}", &ssecurity, &nonce).into_iter().map(|f| f.0).collect();
        assert_eq!(names, ["data", "rc4_hash__", "signature", "ssecurity", "_nonce"]);
    }
}
