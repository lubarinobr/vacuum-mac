//! A small HTTP/1.1 server that only listens on the loopback interface, plus the MCP / REST routing.
//! `/mcp` speaks MCP (JSON-RPC over HTTP); `/v1/tools...` is the plain API. Both call the same tools.
use crate::cloud::CloudSession;
use crate::config::{self, RobotConfig};
use crate::service::{RobotService, ToolError};
use crate::tools;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const MAX_REQUEST_BYTES: usize = 1_000_000;
const SUPPORTED_PROTOCOLS: [&str; 3] = ["2025-06-18", "2025-03-26", "2024-11-05"];

pub struct Request {
    pub method: String,
    pub path: String,
    pub headers: HashMap<String, String>, // lowercased names
    pub body: Vec<u8>,
}

pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
}

impl Response {
    fn json(value: Value, status: u16) -> Self {
        Self { status, body: serde_json::to_vec(&value).unwrap() }
    }
    fn error(status: u16, message: &str) -> Self {
        Self::json(json!({"error": message}), status)
    }
    fn empty(status: u16) -> Self {
        Self { status, body: vec![] }
    }
}

/// What the server runs on: the access token and the robot service, which is rebuilt when the settings change.
pub struct App {
    token: String,
    service: RwLock<Option<Arc<RobotService>>>,
}

impl App {
    pub fn new(token: String) -> Arc<Self> {
        Arc::new(Self { token, service: RwLock::new(None) })
    }

    #[cfg(test)]
    pub fn with_service(token: String, service: Arc<RobotService>) -> Arc<Self> {
        Arc::new(Self { token, service: RwLock::new(Some(service)) })
    }

    /// (Re)builds the robot service from the saved settings and starts polling. The old one stops by itself.
    pub fn reload(&self) -> Result<(), ToolError> {
        let Some(robot) = config::robot() else {
            *self.service.write().unwrap() = None;
            return Err(ToolError::new("No robot is set up yet. Run `vacuumd setup`, or sign in from the Vacuum app."));
        };
        let service = RobotService::new(robot, config::cloud())?;
        service.start_polling();
        *self.service.write().unwrap() = Some(service);
        Ok(())
    }

    pub fn service(&self) -> Result<Arc<RobotService>, ToolError> {
        self.service.read().unwrap().clone().ok_or_else(|| ToolError::new("No robot is set up yet. Run `vacuumd setup`, or sign in from the Vacuum app."))
    }
}

pub async fn serve(port: u16, app: Arc<App>) -> std::io::Result<()> {
    let listener = TcpListener::bind(("127.0.0.1", port)).await?;
    serve_on(listener, app).await
}

pub async fn serve_on(listener: TcpListener, app: Arc<App>) -> std::io::Result<()> {
    loop {
        let (stream, _) = listener.accept().await?;
        let app = app.clone();
        tokio::spawn(async move {
            let _ = handle_connection(stream, &app).await;
        });
    }
}

async fn handle_connection(mut stream: TcpStream, app: &App) -> std::io::Result<()> {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 8192];
    let request = loop {
        match parse(&buffer) {
            Parsed::Complete(request) => break request,
            Parsed::Invalid => return write_response(&mut stream, Response::error(400, "Bad request")).await,
            Parsed::Incomplete => {}
        }
        let n = stream.read(&mut chunk).await?;
        if n == 0 || buffer.len() > MAX_REQUEST_BYTES {
            return Ok(());
        }
        buffer.extend_from_slice(&chunk[..n]);
    };
    let response = route(&request, app).await;
    if std::env::var_os("VACUUMD_LOG").is_some() || response.status >= 400 {
        println!("{} {} -> {}", request.method, request.path, response.status); // no bodies: they hold secrets
    }
    write_response(&mut stream, response).await
}

async fn write_response(stream: &mut TcpStream, response: Response) -> std::io::Result<()> {
    let reason = match response.status {
        200 => "OK", 202 => "Accepted", 400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found", 405 => "Method Not Allowed", _ => "Error",
    };
    let head = format!(
        "HTTP/1.1 {} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        response.status,
        response.body.len()
    );
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(&response.body).await?;
    stream.shutdown().await
}

pub enum Parsed {
    Complete(Request),
    Incomplete,
    Invalid,
}

pub fn parse(data: &[u8]) -> Parsed {
    let Some(separator) = data.windows(4).position(|w| w == b"\r\n\r\n") else { return Parsed::Incomplete };
    let head = String::from_utf8_lossy(&data[..separator]).to_string();
    let mut lines = head.split("\r\n");
    let request_line: Vec<&str> = lines.next().unwrap_or("").split(' ').collect();
    if request_line.len() != 3 {
        return Parsed::Invalid;
    }
    let mut headers = HashMap::new();
    for line in lines {
        let Some((name, value)) = line.split_once(':') else { return Parsed::Invalid };
        headers.insert(name.to_lowercase(), value.trim().to_string());
    }
    let length: usize = match headers.get("content-length").map(|v| v.parse()) {
        None => 0,
        Some(Ok(n)) if n <= MAX_REQUEST_BYTES => n,
        _ => return Parsed::Invalid,
    };
    let body = &data[separator + 4..];
    if body.len() < length {
        return Parsed::Incomplete;
    }
    Parsed::Complete(Request { method: request_line[0].into(), path: request_line[1].into(), headers, body: body[..length].to_vec() })
}

// MARK: - Routing

pub async fn route(request: &Request, app: &App) -> Response {
    let path = request.path.split('?').next().unwrap_or("");
    if request.method == "GET" && path == "/health" {
        return Response::json(json!({"ok": true}), 200);
    }
    // Web pages can reach localhost too. A page on another site is turned away by its Origin / Host,
    // and everything else still needs the token.
    let host_ok = is_local_host(request.headers.get("host").map(String::as_str));
    let origin_ok = request.headers.get("origin").map_or(true, |o| is_local_origin(o));
    if !host_ok || !origin_ok {
        return Response::error(403, "Forbidden");
    }
    if !authorized(request, &app.token) {
        return Response::error(401, "Missing or wrong token");
    }

    match (request.method.as_str(), path) {
        ("POST", "/mcp") => mcp(&request.body, app).await,
        ("GET", "/mcp") | ("DELETE", "/mcp") => Response::error(405, "This server does not offer a stream or sessions"),
        ("GET", "/v1/tools") => Response::json(
            Value::Array(tools::list().into_iter().map(|t| json!({"name": t.name, "description": t.description, "inputSchema": t.schema})).collect()),
            200,
        ),
        ("POST", p) if p.starts_with("/v1/tools/") => {
            let name = &p["/v1/tools/".len()..];
            let args: Value = if request.body.is_empty() { json!({}) } else { serde_json::from_slice(&request.body).unwrap_or(Value::Null) };
            if !args.is_object() {
                return Response::error(400, "The body must be a JSON object");
            }
            if !tools::exists(name) {
                return Response::error(404, "Unknown tool");
            }
            let service = match app.service() {
                Ok(service) => service,
                Err(e) => return Response::error(400, &e.0),
            };
            match tools::call(&service, name, &args).await {
                Ok(value) => Response::json(value, 200),
                Err(e) => Response::error(400, &e.0),
            }
        }
        // Used by the Mac app only; not tools. They let the app keep its own logic (map, zones, schedules)
        // while this server stays the single owner of the connection to the robot.
        ("GET", "/v1/properties") => match app.service() {
            Ok(service) => Response::json(service.properties().await, 200),
            Err(e) => Response::error(400, &e.0),
        },
        ("POST", "/v1/miio") => raw_miio(&request.body, app).await,
        ("POST", "/v1/config") => configure(&request.body, app),
        _ => Response::error(404, "Not found"),
    }
}

/// `{"method", "params", "timeout_ms"?, "retry"?, "channel"?: "drive"}` -> `{"result"}` or `{"error", "kind", "code"?}`.
async fn raw_miio(body: &[u8], app: &App) -> Response {
    let Ok(request) = serde_json::from_slice::<Value>(body) else { return Response::error(400, "The body must be JSON") };
    let Some(method) = request["method"].as_str() else { return Response::error(400, "Missing method") };
    let service = match app.service() {
        Ok(service) => service,
        Err(e) => return Response::error(400, &e.0),
    };
    let timeout = Duration::from_millis(request["timeout_ms"].as_u64().unwrap_or(5000).clamp(50, 60_000));
    let retry = request["retry"].as_bool().unwrap_or(true);
    let drive = request["channel"].as_str() == Some("drive");
    match service.raw(method, request["params"].clone(), timeout, retry, drive).await {
        Ok(result) => Response::json(json!({"result": result}), 200),
        Err(e) => {
            let code = if let crate::miio::MiioError::Device { code, .. } = &e { Some(*code) } else { None };
            Response::json(json!({"error": e.to_string(), "kind": e.kind(), "code": code}), 502)
        }
    }
}

/// `{"robot"?: {ip, token, did}, "cloud"?: {...}}`: saves what's given (readable only by you) and restarts the service.
/// Release builds of the Mac app keep these in the Keychain, so the app hands them over here.
fn configure(body: &[u8], app: &App) -> Response {
    let Ok(request) = serde_json::from_slice::<Value>(body) else { return Response::error(400, "The body must be JSON") };
    if !request["robot"].is_null() {
        let Ok(robot) = serde_json::from_value::<RobotConfig>(request["robot"].clone()) else { return Response::error(400, "Invalid robot settings") };
        if hex::decode(&robot.token).map(|b| b.len()) != Ok(16) {
            return Response::error(400, "The robot token must be 32 hex characters.");
        }
        if config::save_robot(&robot).is_err() {
            return Response::error(500, "Couldn't save the robot settings");
        }
    }
    if !request["cloud"].is_null() {
        let Ok(cloud) = serde_json::from_value::<CloudSession>(request["cloud"].clone()) else { return Response::error(400, "Invalid sign-in") };
        if config::save_cloud(&cloud).is_err() {
            return Response::error(500, "Couldn't save the sign-in");
        }
    }
    match app.reload() {
        Ok(()) => Response::json(json!({"ok": true}), 200),
        Err(e) => Response::error(400, &e.0),
    }
}

fn authorized(request: &Request, token: &str) -> bool {
    let Some(header) = request.headers.get("authorization") else { return false };
    let Some(given) = header.strip_prefix("Bearer ") else { return false };
    let (given, expected) = (given.as_bytes(), token.as_bytes());
    given.len() == expected.len() && given.iter().zip(expected).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0 // constant time
}

pub fn is_local_host(host: Option<&str>) -> bool {
    host.and_then(|h| h.split(':').next()).map_or(false, |name| name == "127.0.0.1" || name == "localhost")
}

pub fn is_local_origin(origin: &str) -> bool {
    let rest = origin.split("://").nth(1).unwrap_or("");
    let host = rest.split('/').next().unwrap_or("").split(':').next().unwrap_or("");
    host == "127.0.0.1" || host == "localhost"
}

// MARK: - MCP

async fn mcp(body: &[u8], app: &App) -> Response {
    let Ok(parsed) = serde_json::from_slice::<Value>(body) else {
        return Response::json(failure(Value::Null, -32700, "Parse error"), 400);
    };
    match parsed {
        Value::Array(batch) => {
            let mut replies = vec![];
            for message in &batch {
                if let Some(reply) = respond(message, app).await {
                    replies.push(reply);
                }
            }
            if replies.is_empty() { Response::empty(202) } else { Response::json(Value::Array(replies), 200) }
        }
        Value::Object(_) => match respond(&parsed, app).await {
            Some(reply) => Response::json(reply, 200),
            None => Response::empty(202),
        },
        _ => Response::json(failure(Value::Null, -32600, "Invalid request"), 400),
    }
}

/// None for notifications, which get no reply.
async fn respond(message: &Value, app: &App) -> Option<Value> {
    let method = message["method"].as_str()?; // a response to us; we never ask anything
    let id = message.get("id")?.clone();
    let params = &message["params"];

    Some(match method {
        "initialize" => {
            let asked = params["protocolVersion"].as_str().unwrap_or("");
            success(id, json!({
                "protocolVersion": if SUPPORTED_PROTOCOLS.contains(&asked) { asked } else { SUPPORTED_PROTOCOLS[0] },
                "capabilities": {"tools": {"listChanged": false}},
                "serverInfo": {"name": "vacuumd", "version": env!("CARGO_PKG_VERSION")},
                "instructions": "Controls the user's Xiaomi robot vacuum over their home network. Check get_status before and after acting.",
            }))
        }
        "ping" => success(id, json!({})),
        "tools/list" => success(id, json!({"tools": tools::list().into_iter().map(|t| json!({
            "name": t.name, "description": t.description, "inputSchema": t.schema,
            "annotations": {"readOnlyHint": t.read_only, "destructiveHint": false, "openWorldHint": false},
        })).collect::<Vec<_>>()})),
        "tools/call" => {
            let Some(name) = params["name"].as_str() else { return Some(failure(id, -32602, "Missing tool name")) };
            if !tools::exists(name) {
                return Some(failure(id, -32602, &format!("Unknown tool '{name}'")));
            }
            let args = if params["arguments"].is_object() { params["arguments"].clone() } else { json!({}) };
            let outcome = match app.service() {
                Ok(service) => tools::call(&service, name, &args).await,
                Err(e) => Err(e),
            };
            match outcome {
                Ok(value) => success(id, json!({"content": [{"type": "text", "text": serde_json::to_string_pretty(&value).unwrap()}], "isError": false})),
                Err(e) => success(id, json!({"content": [{"type": "text", "text": e.0}], "isError": true})),
            }
        }
        _ => failure(id, -32601, "Method not found"),
    })
}

fn success(id: Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

fn failure(id: Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}
