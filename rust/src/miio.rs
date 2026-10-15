//! Local miIO protocol (UDP port 54321), as implemented by python-miio.
//!
//! Packet = 32-byte header + AES-128-CBC(JSON + "\0")
//!   0  magic 0x2131      2  total length      4  unknown (0)
//!   8  device id        12  stamp (seconds)   16  MD5(header[0..<16] + token + payload)
//! key = MD5(token), iv = MD5(key + token)
use crate::crypto;
use serde_json::{json, Value};
use std::time::{Duration, Instant};
use tokio::net::UdpSocket;
use tokio::sync::Mutex;

#[derive(Debug)]
pub enum MiioError {
    Timeout,
    InvalidPacket,
    Socket(String),
    Device { code: i64, message: String },
}

impl std::fmt::Display for MiioError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Timeout => write!(f, "The robot didn't answer. Is it on and connected to Wi-Fi?"),
            Self::InvalidPacket => write!(f, "The robot sent an unexpected reply."),
            Self::Socket(m) => write!(f, "Network error: {m}"),
            Self::Device { code, message } => write!(f, "The robot refused the command ({code}): {message}"),
        }
    }
}

impl MiioError {
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Timeout => "timeout",
            Self::InvalidPacket => "invalid",
            Self::Socket(_) => "socket",
            Self::Device { .. } => "device",
        }
    }
}

pub const HELLO: [u8; 32] = {
    let mut hello = [0xff; 32];
    hello[0] = 0x21;
    hello[1] = 0x31;
    hello[2] = 0x00;
    hello[3] = 0x20;
    hello
};

#[derive(Clone)]
pub struct Packet {
    token: [u8; 16],
    key: [u8; 16],
    iv: [u8; 16],
}

pub struct Decoded {
    pub device_id: u32,
    pub stamp: u32,
    pub payload: Vec<u8>,
}

impl Packet {
    pub fn new(token: [u8; 16]) -> Self {
        let key = crypto::md5(&token);
        let iv = crypto::md5(&[key.as_slice(), token.as_slice()].concat());
        Self { token, key, iv }
    }

    pub fn encode(&self, plaintext: &[u8], device_id: u32, stamp: u32) -> Vec<u8> {
        let encrypted = crypto::aes128_encrypt(plaintext, &self.key, &self.iv);
        let mut header = Vec::with_capacity(16);
        header.extend_from_slice(&0x2131u16.to_be_bytes());
        header.extend_from_slice(&((32 + encrypted.len()) as u16).to_be_bytes());
        header.extend_from_slice(&0u32.to_be_bytes());
        header.extend_from_slice(&device_id.to_be_bytes());
        header.extend_from_slice(&stamp.to_be_bytes());
        let checksum = crypto::md5(&[header.as_slice(), self.token.as_slice(), encrypted.as_slice()].concat());
        [header.as_slice(), checksum.as_slice(), encrypted.as_slice()].concat()
    }

    pub fn decode(&self, packet: &[u8]) -> Result<Decoded, MiioError> {
        if packet.len() < 32 || packet[0] != 0x21 || packet[1] != 0x31 {
            return Err(MiioError::InvalidPacket);
        }
        let device_id = u32::from_be_bytes(packet[8..12].try_into().unwrap());
        let stamp = u32::from_be_bytes(packet[12..16].try_into().unwrap());
        if packet.len() == 32 {
            return Ok(Decoded { device_id, stamp, payload: vec![] });
        }
        let mut payload = crypto::aes128_decrypt(&packet[32..], &self.key, &self.iv).map_err(|_| MiioError::InvalidPacket)?;
        while payload.last() == Some(&0) {
            payload.pop();
        }
        Ok(Decoded { device_id, stamp, payload })
    }
}

struct Inner {
    socket: Option<UdpSocket>,
    device_id: Option<u32>,
    device_stamp: u32,
    stamp_received_at: Instant,
    next_id: i64,
}

/// Talks to one robot. One request at a time.
pub struct MiioClient {
    ip: String,
    packet: Packet,
    inner: Mutex<Inner>,
}

impl MiioClient {
    pub fn new(ip: String, token: [u8; 16]) -> Self {
        Self {
            ip,
            packet: Packet::new(token),
            inner: Mutex::new(Inner {
                socket: None,
                device_id: None,
                device_stamp: 0,
                stamp_received_at: Instant::now(),
                next_id: 1 + (rand::random::<u16>() as i64 % 10_000),
            }),
        }
    }

    /// Sends {"id","method","params"} and returns the reply's "result".
    /// `timeout` is how long to wait for the reply; without `retry` a lost reply just fails with `Timeout`.
    pub async fn send(&self, method: &str, params: Value, timeout: Duration, retry: bool) -> Result<Value, MiioError> {
        let mut inner = self.inner.lock().await;
        if !retry {
            return self.send_once(&mut inner, method, &params, timeout).await;
        }
        match self.send_once(&mut inner, method, &params, timeout).await {
            Err(MiioError::Timeout) => {
                inner.device_id = None; // re-handshake and try once more
                self.send_once(&mut inner, method, &params, timeout).await
            }
            Err(MiioError::Socket(_)) => {
                inner.socket = None; // a failed socket stays broken; start over with a fresh one
                inner.device_id = None;
                self.send_once(&mut inner, method, &params, timeout).await
            }
            other => other,
        }
    }

    pub async fn send_default(&self, method: &str, params: Value) -> Result<Value, MiioError> {
        self.send(method, params, Duration::from_secs(5), true).await
    }

    async fn open_socket(&self) -> Result<UdpSocket, MiioError> {
        let socket = UdpSocket::bind("0.0.0.0:0").await.map_err(|e| MiioError::Socket(e.to_string()))?;
        // "host:port" is accepted so tests can talk to a fake robot; real robots always use 54321.
        let target = if self.ip.contains(':') { self.ip.clone() } else { format!("{}:54321", self.ip) };
        socket.connect(target).await.map_err(|e| MiioError::Socket(e.to_string()))?;
        Ok(socket)
    }

    async fn send_once(&self, inner: &mut Inner, method: &str, params: &Value, timeout: Duration) -> Result<Value, MiioError> {
        if inner.socket.is_none() {
            inner.socket = Some(self.open_socket().await?);
        }
        if inner.device_id.is_none() {
            self.handshake(inner).await?;
        }
        inner.next_id += 1;
        let id = inner.next_id;
        let mut body = serde_json::to_vec(&json!({"id": id, "method": method, "params": params})).unwrap();
        body.push(0);
        let stamp = inner
            .device_stamp
            .wrapping_add(inner.stamp_received_at.elapsed().as_secs() as u32)
            .wrapping_add(1);
        let packet = self.packet.encode(&body, inner.device_id.unwrap(), stamp);
        self.write(inner, &packet).await?;

        let deadline = Instant::now() + timeout;
        loop {
            let raw = self.read(inner, deadline).await?;
            let decoded = self.packet.decode(&raw)?;
            inner.device_stamp = decoded.stamp;
            inner.stamp_received_at = Instant::now();
            let Ok(reply) = serde_json::from_slice::<Value>(&decoded.payload) else { continue };
            if reply["id"].as_i64() != Some(id) {
                continue; // stale reply from an earlier request
            }
            if let Some(error) = reply.get("error").filter(|e| e.is_object()) {
                return Err(MiioError::Device {
                    code: error["code"].as_i64().unwrap_or(-1),
                    message: error["message"].as_str().unwrap_or("").to_string(),
                });
            }
            return Ok(reply.get("result").cloned().unwrap_or(Value::Null));
        }
    }

    async fn handshake(&self, inner: &mut Inner) -> Result<(), MiioError> {
        self.write(inner, &HELLO).await?;
        let raw = self.read(inner, Instant::now() + Duration::from_secs(5)).await?;
        let decoded = self.packet.decode(&raw)?;
        inner.device_id = Some(decoded.device_id);
        inner.device_stamp = decoded.stamp;
        inner.stamp_received_at = Instant::now();
        Ok(())
    }

    async fn write(&self, inner: &mut Inner, data: &[u8]) -> Result<(), MiioError> {
        let socket = inner.socket.as_ref().ok_or(MiioError::Socket("no socket".into()))?;
        let mut scratch = vec![0u8; 2048]; // heap: a 64 KB array makes every future that awaits this huge
        while socket.try_recv(&mut scratch).is_ok() {} // drop leftovers from earlier requests
        if let Err(e) = socket.send(data).await {
            inner.socket = None;
            inner.device_id = None;
            return Err(MiioError::Socket(e.to_string()));
        }
        Ok(())
    }

    async fn read(&self, inner: &mut Inner, deadline: Instant) -> Result<Vec<u8>, MiioError> {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(MiioError::Timeout);
        }
        let socket = inner.socket.as_ref().ok_or(MiioError::Socket("no socket".into()))?;
        let mut buffer = vec![0u8; 65_536];
        match tokio::time::timeout(remaining, socket.recv(&mut buffer)).await {
            Err(_) => Err(MiioError::Timeout),
            Ok(Ok(count)) => {
                buffer.truncate(count);
                Ok(buffer)
            }
            Ok(Err(e)) => {
                inner.socket = None;
                inner.device_id = None;
                Err(MiioError::Socket(e.to_string()))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Expected value generated with python-miio, the same vector the Swift tests use.
    const REQUEST: &str = r#"{"id": 1, "method": "get_properties", "params": [{"did": "x", "siid": 3, "piid": 1}]}"#;
    const EXPECTED: &str = "213100800000000043f5b7a16553f1002804c4ac14f619c9db34f958a39345d92a36b2b7afa85bd6a9f1ed82b485a3d658c96ba3b375bd3a49af5151f5155f163087aefff022bc1b2374956dfc606d5805505f849e0fee2e061f2e9f401f0b99d28ff527d021af9308c852ea016fcf43d9c95e6a860b7477bddb54b98e5e369a";

    fn packet() -> Packet {
        Packet::new(hex::decode("00112233445566778899aabbccddeeff").unwrap().try_into().unwrap())
    }

    #[test]
    fn encodes_exactly_like_python_miio() {
        let mut plaintext = REQUEST.as_bytes().to_vec();
        plaintext.push(0);
        assert_eq!(hex::encode(packet().encode(&plaintext, 0x43f5b7a1, 1_700_000_000)), EXPECTED);
    }

    #[test]
    fn decodes_python_miio_packet() {
        let decoded = packet().decode(&hex::decode(EXPECTED).unwrap()).unwrap();
        assert_eq!(decoded.device_id, 0x43f5b7a1);
        assert_eq!(decoded.stamp, 1_700_000_000);
        assert_eq!(String::from_utf8(decoded.payload).unwrap(), REQUEST);
    }

    #[test]
    fn rejects_garbage() {
        assert!(packet().decode(&[1, 2, 3]).is_err());
    }
}
