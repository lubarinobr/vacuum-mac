//! A small HTTP/1.1 server that only listens on the loopback interface, plus the MCP / REST routing.
//! `/mcp` speaks MCP (JSON-RPC over HTTP); `/v1/tools...` is the plain API. Both call the same tools.
use crate::audit;
use crate::cloud::CloudSession;
use crate::config::{self, RobotConfig};
use crate::policy;
use crate::service::{RobotService, ToolError};
use crate::tools;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Notify, Semaphore};

const MAX_REQUEST_BYTES: usize = 1_000_000;
const MAX_HEADER_BYTES: usize = 16_000;
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

/// What the access token may do. Agents only get the tools; the Mac app also gets the raw robot channel,
/// the settings and shutdown.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Scope {
    Agent,
    App,
}

impl Scope {
    fn name(self) -> &'static str {
        match self {
            Scope::Agent => "agent",
            Scope::App => "app",
        }
    }
}

/// What the server runs on: the two access tokens and the robot service, which is rebuilt when the settings change.
pub struct App {
    app_token: String,
    mcp_token: String,
    service: RwLock<Option<Arc<RobotService>>>,
    /// Notified when the app (or `vacuumd logout`) asks the server to stop.
    pub shutdown: Notify,
}

impl App {
    pub fn new(app_token: String, mcp_token: String) -> Arc<Self> {
        Arc::new(Self { app_token, mcp_token, service: RwLock::new(None), shutdown: Notify::new() })
    }

    #[cfg(test)]
    pub fn with_service(app_token: String, mcp_token: String, service: Arc<RobotService>) -> Arc<Self> {
        Arc::new(Self { app_token, mcp_token, service: RwLock::new(Some(service)), shutdown: Notify::new() })
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

/// Protection against a local program that opens many connections or never finishes a request.
#[derive(Clone, Copy)]
pub struct Limits {
    pub max_connections: usize,
    /// How long a client has to send its whole request.
    pub request_timeout: Duration,
}

impl Limits {
    pub fn from_env() -> Self {
        let number = |name: &str| std::env::var(name).ok().and_then(|v| v.parse::<u64>().ok());
        Self {
            max_connections: number("VACUUMD_MAX_CONNECTIONS").unwrap_or(64) as usize,
            request_timeout: Duration::from_millis(number("VACUUMD_REQUEST_TIMEOUT_MS").unwrap_or(10_000)),
        }
    }
}

pub async fn serve(port: u16, app: Arc<App>) -> std::io::Result<()> {
    let listener = TcpListener::bind(("127.0.0.1", port)).await?;
    serve_on(listener, app).await
}

pub async fn serve_on(listener: TcpListener, app: Arc<App>) -> std::io::Result<()> {
    serve_with(listener, app, Limits::from_env()).await
}

pub async fn serve_with(listener: TcpListener, app: Arc<App>, limits: Limits) -> std::io::Result<()> {
    let permits = Arc::new(Semaphore::new(limits.max_connections));
    loop {
        let (stream, _) = listener.accept().await?;
        let app = app.clone();
        match permits.clone().try_acquire_owned() {
            Ok(permit) => {
                tokio::spawn(async move {
                    let _permit = permit; // released when this connection ends
                    let _ = handle_connection(stream, &app, limits).await;
                });
            }
            Err(_) => {
                tokio::spawn(async move {
                    let mut stream = stream;
                    let _ = tokio::time::timeout(Duration::from_secs(2), write_response(&mut stream, Response::error(503, "Too many connections"))).await;
                });
            }
        }
    }
}

/// Reads one request. `Err(None)` means: just close (the client went away); `Err(Some(response))`: answer, then close.
async fn read_request(stream: &mut TcpStream) -> Result<Request, Option<Response>> {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        match parse(&buffer) {
            Parsed::Complete(request) => return Ok(request),
            Parsed::Invalid => return Err(Some(Response::error(400, "Bad request"))),
            Parsed::Incomplete => {}
        }
        let n = stream.read(&mut chunk).await.map_err(|_| None)?;
        if n == 0 || buffer.len() > MAX_REQUEST_BYTES {
            return Err(None);
        }
        buffer.extend_from_slice(&chunk[..n]);
    }
}

async fn handle_connection(mut stream: TcpStream, app: &App, limits: Limits) -> std::io::Result<()> {
    let request = match tokio::time::timeout(limits.request_timeout, read_request(&mut stream)).await {
        Err(_) => return write_response_within(&mut stream, Response::error(408, "The request took too long")).await,
        Ok(Err(None)) => return Ok(()),
        Ok(Err(Some(response))) => return write_response_within(&mut stream, response).await,
        Ok(Ok(request)) => request,
    };
    let response = route(&request, app).await;
    if std::env::var_os("VACUUMD_LOG").is_some() || response.status >= 400 {
        println!("{} {} -> {}", request.method, request.path, response.status); // no bodies: they hold secrets
    }
    write_response_within(&mut stream, response).await
}

async fn write_response_within(stream: &mut TcpStream, response: Response) -> std::io::Result<()> {
    tokio::time::timeout(Duration::from_secs(10), write_response(stream, response)).await.unwrap_or(Ok(()))
}

async fn write_response(stream: &mut TcpStream, response: Response) -> std::io::Result<()> {
    let reason = match response.status {
        200 => "OK", 202 => "Accepted", 400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found",
        405 => "Method Not Allowed", 408 => "Request Timeout", 503 => "Service Unavailable", _ => "Error",
    };
    let head = format!(
        "HTTP/1.1 {} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        response.status,
        response.body.len()
    );
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(&response.body).await?;
    stream.shutdown().await?;
    // A client that is still sending (a request we refused halfway) would get a connection reset instead of
    // our answer if we closed now. Read what is left for a moment, up to a limit.
    let mut sink = [0u8; 4096];
    let mut drained = 0;
    while drained < 100_000 {
        match tokio::time::timeout(Duration::from_millis(300), stream.read(&mut sink)).await {
            Ok(Ok(n)) if n > 0 => drained += n,
            _ => break,
        }
    }
    Ok(())
}

pub enum Parsed {
    Complete(Request),
    Incomplete,
    Invalid,
}

pub fn parse(data: &[u8]) -> Parsed {
    let Some(separator) = data.windows(4).position(|w| w == b"\r\n\r\n") else {
        return if data.len() > MAX_HEADER_BYTES { Parsed::Invalid } else { Parsed::Incomplete };
    };
    if separator > MAX_HEADER_BYTES {
        return Parsed::Invalid;
    }
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
    if headers.contains_key("transfer-encoding") {
        return Parsed::Invalid; // chunked bodies aren't supported, and guessing where one ends is how requests get smuggled
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
    // and everything else still needs a token.
    let host_ok = is_local_host(request.headers.get("host").map(String::as_str));
    let origin_ok = request.headers.get("origin").map_or(true, |o| is_local_origin(o));
    if !host_ok || !origin_ok {
        audit::record(json!({"event": "denied", "reason": "request from another site or host", "path": path}));
        return Response::error(403, "Forbidden");
    }
    let Some(scope) = scope_of(request, app) else {
        audit::record(json!({"event": "denied", "reason": "missing or wrong token", "path": path}));
        return Response::error(401, "Missing or wrong token");
    };
    // Only the Mac app's token may use the raw robot channel, the settings and shutdown.
    let app_only = matches!(path, "/v1/properties" | "/v1/miio" | "/v1/config" | "/v1/shutdown");
    if app_only && scope != Scope::App {
        audit::record(json!({"event": "denied", "reason": "agent token used on an app-only endpoint", "path": path}));
        return Response::error(403, "This token can only use the agent tools.");
    }

    match (request.method.as_str(), path) {
        ("POST", "/mcp") => mcp(&request.body, app, scope).await,
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
            match run_tool(&service, "tools-api", scope, name, &args).await {
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
        // The robot and sign-in vacuumd holds, so the Mac app doesn't need a copy of its own (in the Keychain).
        ("GET", "/v1/config") => Response::json(config_payload(config::robot(), config::cloud()), 200),
        ("POST", "/v1/config") => configure(&request.body, app),
        ("POST", "/v1/shutdown") => {
            audit::record(json!({"event": "shutdown", "via": "app"}));
            app.shutdown.notify_one();
            Response::json(json!({"ok": true}), 200)
        }
        _ => Response::error(404, "Not found"),
    }
}

/// Runs a tool and records what happened (successful reads like get_status are left out: they'd bury the rest).
async fn run_tool(service: &RobotService, via: &str, scope: Scope, name: &str, args: &Value) -> Result<Value, ToolError> {
    let result = tools::call(service, name, args).await;
    let read_only = tools::list().iter().any(|t| t.name == name && t.read_only);
    if !(read_only && result.is_ok()) {
        audit::record(json!({"event": "tool", "via": via, "as": scope.name(), "tool": name, "args": args, "ok": result.is_ok(), "error": result.as_ref().err().map(|e| e.0.clone())}));
    }
    result
}

fn describe_raw(method: &str, params: &Value) -> String {
    match method {
        "action" => format!("action {}.{}", params["siid"], params["aiid"]),
        _ => format!(
            "{method} {}",
            params.as_array().map(|items| items.iter().map(|i| format!("{}.{}", i["siid"], i["piid"])).collect::<Vec<_>>().join(", ")).unwrap_or_default()
        ),
    }
}

/// `{"method", "params", "timeout_ms"?, "retry"?, "channel"?: "drive"}` -> `{"result"}` or `{"error", "kind", "code"?}`.
async fn raw_miio(body: &[u8], app: &App) -> Response {
    let Ok(request) = serde_json::from_slice::<Value>(body) else { return Response::error(400, "The body must be JSON") };
    let Some(method) = request["method"].as_str() else { return Response::error(400, "Missing method") };
    if let Err(reason) = policy::check_raw(method, &request["params"]) {
        audit::record(json!({"event": "denied", "reason": "raw robot request not allowed", "what": describe_raw(method, &request["params"]), "detail": reason}));
        return Response::error(403, &reason);
    }
    // Everything that changes something is recorded. Steering sends ~6 commands a second, so it is noted
    // once every 10 seconds instead.
    if method != "get_properties" {
        static LAST_DRIVE_NOTE: std::sync::Mutex<Option<std::time::Instant>> = std::sync::Mutex::new(None);
        let driving = method == "set_properties" && request["params"][0]["siid"] == 4 && request["params"][0]["piid"] == 15;
        let mut last = LAST_DRIVE_NOTE.lock().unwrap_or_else(|e| e.into_inner());
        if !driving || last.map_or(true, |t| t.elapsed() > Duration::from_secs(10)) {
            if driving {
                *last = Some(std::time::Instant::now());
            }
            audit::record(json!({"event": "raw", "via": "app", "what": describe_raw(method, &request["params"])}));
        }
    }
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

/// What `GET /v1/config` returns: the saved robot and Xiaomi sign-in, or null for what isn't set up yet.
fn config_payload(robot: Option<RobotConfig>, cloud: Option<CloudSession>) -> Value {
    json!({"robot": robot, "cloud": cloud})
}

/// `{"robot"?: {ip, token, did}, "cloud"?: {...}}`: checks and saves what's given (readable only by you)
/// and restarts the service. Release builds of the Mac app keep these in the Keychain, so the app hands them over here.
fn configure(body: &[u8], app: &App) -> Response {
    let Ok(request) = serde_json::from_slice::<Value>(body) else { return Response::error(400, "The body must be JSON") };
    // Check everything before saving anything, so a bad request changes nothing.
    let robot = if request["robot"].is_null() {
        None
    } else {
        let Ok(robot) = serde_json::from_value::<RobotConfig>(request["robot"].clone()) else { return Response::error(400, "Invalid robot settings") };
        if let Err(reason) = policy::validate_robot(&robot) {
            audit::record(json!({"event": "denied", "reason": "settings refused", "detail": reason}));
            return Response::error(400, &reason);
        }
        Some(robot)
    };
    let cloud = if request["cloud"].is_null() {
        None
    } else {
        let Ok(cloud) = serde_json::from_value::<CloudSession>(request["cloud"].clone()) else { return Response::error(400, "Invalid sign-in") };
        if let Err(reason) = policy::validate_cloud(&cloud) {
            audit::record(json!({"event": "denied", "reason": "settings refused", "detail": reason}));
            return Response::error(400, &reason);
        }
        Some(cloud)
    };
    if let Some(robot) = &robot {
        if config::save_robot(robot).is_err() {
            return Response::error(500, "Couldn't save the robot settings");
        }
    }
    if let Some(cloud) = &cloud {
        if config::save_cloud(cloud).is_err() {
            return Response::error(500, "Couldn't save the sign-in");
        }
    }
    audit::record(json!({"event": "settings-updated", "via": "app", "robot": robot.is_some(), "cloud": cloud.is_some()}));
    match app.reload() {
        Ok(()) => Response::json(json!({"ok": true}), 200),
        Err(e) => Response::error(400, &e.0),
    }
}

fn constant_time_eq(given: &[u8], expected: &[u8]) -> bool {
    given.len() == expected.len() && given.iter().zip(expected).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0
}

fn scope_of(request: &Request, app: &App) -> Option<Scope> {
    let header = request.headers.get("authorization")?;
    let given = header.strip_prefix("Bearer ")?.as_bytes();
    // Both are compared every time, so the time taken doesn't say which token was close.
    let is_app = constant_time_eq(given, app.app_token.as_bytes());
    let is_agent = constant_time_eq(given, app.mcp_token.as_bytes());
    if is_app { Some(Scope::App) } else if is_agent { Some(Scope::Agent) } else { None }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_saved_settings_have_the_shape_the_mac_app_reads() {
        let robot = RobotConfig { ip: "192.168.1.20".into(), token: "ab".repeat(16), did: "42".into() };
        let cloud = CloudSession { server: "de".into(), user_id: "7".into(), ssecurity: "s".into(), service_token: "t".into(), agent: "a".into() };
        let payload = config_payload(Some(robot), Some(cloud));
        assert_eq!(payload["robot"]["ip"], "192.168.1.20");
        assert_eq!(payload["robot"]["did"], "42");
        assert_eq!(payload["cloud"]["serviceToken"], "t", "camelCase, like the app's CloudSession");
        assert_eq!(payload["cloud"]["userId"], "7");
        let nothing = config_payload(None, None);
        assert!(nothing["robot"].is_null() && nothing["cloud"].is_null());
    }
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

async fn mcp(body: &[u8], app: &App, scope: Scope) -> Response {
    let Ok(parsed) = serde_json::from_slice::<Value>(body) else {
        return Response::json(failure(Value::Null, -32700, "Parse error"), 400);
    };
    match parsed {
        Value::Array(batch) => {
            let mut replies = vec![];
            for message in &batch {
                if let Some(reply) = respond(message, app, scope).await {
                    replies.push(reply);
                }
            }
            if replies.is_empty() { Response::empty(202) } else { Response::json(Value::Array(replies), 200) }
        }
        Value::Object(_) => match respond(&parsed, app, scope).await {
            Some(reply) => Response::json(reply, 200),
            None => Response::empty(202),
        },
        _ => Response::json(failure(Value::Null, -32600, "Invalid request"), 400),
    }
}

/// None for notifications, which get no reply.
async fn respond(message: &Value, app: &App, scope: Scope) -> Option<Value> {
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
                Ok(service) => run_tool(&service, "mcp", scope, name, &args).await,
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
