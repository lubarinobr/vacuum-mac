//! End-to-end tests: the real server and robot service talk to a fake robot that speaks the miIO protocol over UDP.
use crate::config::RobotConfig;
use crate::map::{Cell, Header, VacuumMap};
use crate::miio::Packet;
use crate::server::{self, App};
use crate::service::RobotService;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, Once};
use tokio::net::{TcpListener, UdpSocket};

const TOKEN: &str = "00112233445566778899aabbccddeeff";
const API_TOKEN: &str = "test-token-test-token-test-token-0000";

static INIT: Once = Once::new();

/// Points the settings folder at a temp dir (never the real one) with a room name and a room setting.
fn isolate_settings() {
    INIT.call_once(|| {
        let dir = std::env::temp_dir().join(format!("vacuumd-tests-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("room-names.json"), r#"{"3":"Kitchen"}"#).unwrap();
        std::fs::write(dir.join("room-preferences.json"), r#"{"5":{"suction":3,"water":1,"repeats":2}}"#).unwrap();
        unsafe { std::env::set_var("VACUUMD_DIR", &dir) };
        unsafe { std::env::set_var("VACUUMD_MAP_DIR", dir.join("maps")) };
        unsafe { std::env::set_var("VACUUMD_EDIT_SETTLE_MS", "10") };
    });
}

/// A pretend robot: answers the miIO handshake, get_properties, set_properties and action, and records what it was asked.
struct FakeRobot {
    port: u16,
    requests: Arc<Mutex<Vec<Value>>>,
    properties: Arc<Mutex<HashMap<(u32, u32), Value>>>,
    /// Properties the robot acknowledges but doesn't change (like refusing a mode without mop pads).
    ignored_writes: Arc<Mutex<Vec<(u32, u32)>>>,
    /// Replies for specific actions (siid, aiid), instead of the default {"code": 0, "out": []}.
    action_replies: Arc<Mutex<HashMap<(u64, u64), Value>>>,
}

impl FakeRobot {
    async fn start() -> Self {
        let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let port = socket.local_addr().unwrap().port();
        let requests = Arc::new(Mutex::new(vec![]));
        let properties: Arc<Mutex<HashMap<(u32, u32), Value>>> = Arc::new(Mutex::new(HashMap::from([
            ((2, 1), json!(13)), ((2, 2), json!(0)), ((2, 3), json!(1)), ((3, 1), json!(87)), ((4, 5), json!(2)),
            ((4, 23), json!(0x0102_0302)), ((9, 2), json!(17)), ((5, 1), json!(true)), ((5, 2), json!("22:00")), ((5, 3), json!("08:00")),
            ((12, 3), json!(307)),
        ])));
        let ignored_writes = Arc::new(Mutex::new(vec![]));
        let action_replies: Arc<Mutex<HashMap<(u64, u64), Value>>> = Arc::new(Mutex::new(HashMap::new()));
        let replies = action_replies.clone();
        let packet = Packet::new(hex::decode(TOKEN).unwrap().try_into().unwrap());
        let (log, props, ignored) = (requests.clone(), properties.clone(), ignored_writes.clone());
        tokio::spawn(async move {
            let mut buffer = vec![0u8; 65_536];
            loop {
                let Ok((n, from)) = socket.recv_from(&mut buffer).await else { return };
                let data = &buffer[..n];
                if n == 32 {
                    let mut hello = vec![0x21, 0x31, 0x00, 0x20, 0, 0, 0, 0];
                    hello.extend_from_slice(&0x1234u32.to_be_bytes());
                    hello.extend_from_slice(&100u32.to_be_bytes());
                    hello.extend_from_slice(&[0u8; 16]);
                    let _ = socket.send_to(&hello, from).await;
                    continue;
                }
                let Ok(decoded) = packet.decode(data) else { continue };
                let Ok(request) = serde_json::from_slice::<Value>(&decoded.payload) else { continue };
                log.lock().unwrap().push(request.clone());
                let result = match request["method"].as_str().unwrap_or("") {
                    "get_properties" => Value::Array(
                        request["params"].as_array().unwrap().iter().map(|p| {
                            let key = (p["siid"].as_u64().unwrap() as u32, p["piid"].as_u64().unwrap() as u32);
                            match props.lock().unwrap().get(&key) {
                                Some(v) => json!({"did": p["did"], "siid": key.0, "piid": key.1, "code": 0, "value": v}),
                                None => json!({"did": p["did"], "siid": key.0, "piid": key.1, "code": -4001}),
                            }
                        }).collect(),
                    ),
                    "set_properties" => Value::Array(
                        request["params"].as_array().unwrap().iter().map(|p| {
                            let key = (p["siid"].as_u64().unwrap_or(0) as u32, p["piid"].as_u64().unwrap_or(0) as u32);
                            if !ignored.lock().unwrap().contains(&key) {
                                props.lock().unwrap().insert(key, p["value"].clone());
                            }
                            json!({"did": p["did"], "siid": p["siid"], "piid": p["piid"], "code": 0})
                        }).collect(),
                    ),
                    "action" => {
                        let key = (request["params"]["siid"].as_u64().unwrap_or(0), request["params"]["aiid"].as_u64().unwrap_or(0));
                        replies.lock().unwrap().get(&key).cloned().unwrap_or_else(|| json!({"code": 0, "out": []}))
                    }
                    "never" => continue, // the robot "didn't hear" this one
                    _ => {
                        let error = json!({"id": request["id"], "error": {"code": -9999, "message": "unknown method"}});
                        let mut body = serde_json::to_vec(&error).unwrap();
                        body.push(0);
                        let _ = socket.send_to(&packet.encode(&body, 0x1234, 101), from).await;
                        continue;
                    }
                };
                let mut body = serde_json::to_vec(&json!({"id": request["id"], "result": result})).unwrap();
                body.push(0);
                let _ = socket.send_to(&packet.encode(&body, 0x1234, 101), from).await;
            }
        });
        FakeRobot { port, requests, properties, ignored_writes, action_replies }
    }

    fn methods(&self) -> Vec<String> {
        self.requests.lock().unwrap().iter().map(|r| r["method"].as_str().unwrap().to_string()).collect()
    }

    /// Requests of one kind, e.g. every action sent.
    fn requests(&self, method: &str) -> Vec<Value> {
        self.requests.lock().unwrap().iter().filter(|r| r["method"] == method).cloned().collect()
    }
}

struct Harness {
    robot: FakeRobot,
    base: String,
    http: reqwest::Client,
    service: Arc<RobotService>,
}

impl Harness {
    async fn start() -> Self {
        isolate_settings();
        let robot = FakeRobot::start().await;
        let config = RobotConfig { ip: format!("127.0.0.1:{}", robot.port), token: TOKEN.into(), did: "123".into() };
        let service = RobotService::new(config, None).unwrap();
        let app = App::with_service(API_TOKEN.into(), service.clone());
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(server::serve_on(listener, app));
        Harness { robot, base, http: reqwest::Client::new(), service }
    }

    async fn tool(&self, name: &str, args: Value) -> (u16, Value) {
        let response = self.http.post(format!("{}/v1/tools/{name}", self.base)).bearer_auth(API_TOKEN).body(args.to_string()).send().await.unwrap();
        (response.status().as_u16(), response.json().await.unwrap_or(Value::Null))
    }

    async fn mcp(&self, body: Value) -> Value {
        self.http.post(format!("{}/mcp", self.base)).bearer_auth(API_TOKEN).body(body.to_string()).send().await.unwrap().json().await.unwrap()
    }

    /// Rooms 3 (2 cells), 5 (3 cells) and 7 (1 cell) on a 100 mm grid.
    fn inject_rooms(&self) {
        let (width, height) = (6, 6);
        let mut cells = vec![Cell::Outside; width * height];
        for x in 0..2 {
            cells[x] = Cell::Room(3);
        }
        for x in 2..5 {
            cells[x] = Cell::Room(5);
        }
        cells[width] = Cell::Room(7);
        self.service.inject_map(VacuumMap { header: Header { map_id: 0, robot: None, charger: None, width, height, grid_size: 100, left: 0, top: 0 },
            cells,
            zones: Default::default(),
            saved_map_id: Some(12),
            neighbors: HashMap::from([(3, [5].into()), (5, [3, 7].into()), (7, [5].into())]),
        });
    }

    fn action_with(&self, siid: u64, aiid: u64) -> Vec<Value> {
        self.robot.requests("action").into_iter().filter(|r| r["params"]["siid"] == siid && r["params"]["aiid"] == aiid).collect()
    }
}

// MARK: - Status

#[tokio::test]
async fn status_is_read_from_the_robot_and_translated() {
    let h = Harness::start().await;
    let (code, status) = h.tool("get_status", json!({"fresh": true})).await;
    assert_eq!(code, 200);
    assert_eq!(status["online"], true);
    assert_eq!(status["state"], "Fully charged");
    assert_eq!(status["batteryPercent"], 87);
    assert_eq!(status["suction"], "Standard");
    assert_eq!(status["mopLevel"], "Medium");
    assert_eq!(status["cleaningMode"], "Vacuuming"); // packed value ...02 -> raw mode 2
    assert_eq!(status["consumables"]["mainBrushPercentLeft"], 17);
    assert_eq!(status["doNotDisturb"], "22:00 - 08:00");
    assert_eq!(status["totals"]["cleans"], 307);
    assert!(status.get("fault").is_none(), "no fault when the code is 0");
}

#[tokio::test]
async fn a_fault_is_named() {
    let h = Harness::start().await;
    h.robot.properties.lock().unwrap().insert((2, 2), json!(11));
    let (_, status) = h.tool("get_status", json!({"fresh": true})).await;
    assert_eq!(status["fault"]["code"], 11);
    assert_eq!(status["fault"]["description"], "Box full");
}

#[tokio::test]
async fn status_without_fresh_uses_the_last_reading() {
    let h = Harness::start().await;
    h.tool("get_status", json!({})).await; // the first call has to read
    let before = h.robot.requests("get_properties").len();
    for _ in 0..3 {
        h.tool("get_status", json!({})).await;
    }
    assert_eq!(h.robot.requests("get_properties").len(), before, "cached readings must not hit the robot");
}

#[tokio::test]
async fn an_unreachable_robot_is_reported_offline() {
    isolate_settings();
    let silent = UdpSocket::bind("127.0.0.1:0").await.unwrap(); // never answers
    let config = RobotConfig { ip: format!("127.0.0.1:{}", silent.local_addr().unwrap().port()), token: TOKEN.into(), did: "1".into() };
    let service = RobotService::new(config, None).unwrap();
    let status = service.status(true).await;
    assert!(!status.online);
    assert!(status.error.unwrap().contains("didn't answer"));
}

// MARK: - Commands and settings

#[tokio::test]
async fn simple_commands_send_the_right_actions() {
    let h = Harness::start().await;
    for (tool, siid, aiid) in [("start_cleaning", 2, 1), ("stop_cleaning", 2, 2), ("go_home", 3, 1), ("locate", 7, 1), ("empty_bin", 2, 4)] {
        let (code, reply) = h.tool(tool, json!({})).await;
        assert_eq!(code, 200, "{tool}");
        assert_eq!(reply["ok"], true);
        assert_eq!(h.action_with(siid, aiid).len(), 1, "{tool} should send action {siid}.{aiid} once");
    }
}

#[tokio::test]
async fn settings_are_written_and_validated() {
    let h = Harness::start().await;
    h.tool("set_suction", json!({"level": "max"})).await;
    h.tool("set_mop_level", json!({"level": "high"})).await;
    let sets = h.robot.requests("set_properties");
    assert_eq!(sets[0]["params"][0]["siid"], 2);
    assert_eq!(sets[0]["params"][0]["value"], 3);
    assert_eq!(sets[1]["params"][0]["piid"], 5);
    assert_eq!(sets[1]["params"][0]["value"], 3);

    let before = h.robot.requests("set_properties").len();
    let (code, reply) = h.tool("set_suction", json!({"level": "turbo"})).await;
    assert_eq!(code, 400);
    assert!(reply["error"].as_str().unwrap().contains("silent, standard, strong, max"));
    let (code, _) = h.tool("set_suction", json!({})).await;
    assert_eq!(code, 400);
    assert_eq!(h.robot.requests("set_properties").len(), before, "bad input must never reach the robot");
}

#[tokio::test]
async fn cleaning_mode_keeps_the_other_bits() {
    let h = Harness::start().await;
    let (code, _) = h.tool("set_cleaning_mode", json!({"mode": "mop"})).await;
    assert_eq!(code, 200);
    let value = h.robot.requests("set_properties").last().unwrap()["params"][0]["value"].as_i64().unwrap();
    assert_eq!(value & !0x03, 0x0102_0300, "mop-washing settings in the higher bytes must be kept");
    assert_eq!(value & 0x03, 1);
}

#[tokio::test]
async fn a_refused_cleaning_mode_is_reported_not_ignored() {
    let h = Harness::start().await;
    h.robot.ignored_writes.lock().unwrap().push((4, 23));
    let (code, reply) = h.tool("set_cleaning_mode", json!({"mode": "mop"})).await;
    assert_eq!(code, 400);
    assert!(reply["error"].as_str().unwrap().contains("mop pads"), "{reply}");
}

// MARK: - Rooms

#[tokio::test]
async fn rooms_are_listed_with_names_and_saved_settings() {
    let h = Harness::start().await;
    h.inject_rooms();
    let (code, rooms) = h.tool("list_rooms", json!({})).await;
    assert_eq!(code, 200);
    let rooms = rooms.as_array().unwrap();
    assert_eq!(rooms.iter().map(|r| r["id"].as_u64().unwrap()).collect::<Vec<_>>(), [3, 5, 7]);
    assert_eq!(rooms[0]["name"], "Kitchen");
    assert_eq!(rooms[1]["name"], "Room 5");
    assert_eq!(rooms[1]["suction"], "Max");
    assert_eq!(rooms[1]["mopLevel"], "Low");
    assert_eq!(rooms[1]["repeats"], 2);
    assert_eq!(rooms[0]["repeats"], 1);
}

#[tokio::test]
async fn clean_rooms_accepts_names_and_ids_and_applies_saved_settings() {
    let h = Harness::start().await;
    h.inject_rooms();
    let (code, reply) = h.tool("clean_rooms", json!({"rooms": ["kitchen", 5]})).await;
    assert_eq!(code, 200, "{reply}");
    let start = h.action_with(4, 1);
    assert_eq!(start.len(), 1);
    let params = start[0]["params"]["in"].as_array().unwrap();
    assert_eq!(params[0]["piid"], 1);
    assert_eq!(params[0]["value"], 18);
    let data: Value = serde_json::from_str(params[1]["value"].as_str().unwrap()).unwrap();
    // [room, repeats, suction, water, 1]: the kitchen uses the robot's current settings, room 5 its saved ones.
    assert_eq!(data["selects"], json!([[3, 1, 1, 2, 1], [5, 2, 3, 1, 1]]));
}

#[tokio::test]
async fn clean_rooms_overrides_win_and_repeats_are_capped() {
    let h = Harness::start().await;
    h.inject_rooms();
    h.tool("clean_rooms", json!({"rooms": [7], "suction": "silent", "mop_level": "high", "repeats": 9})).await;
    let data: Value = serde_json::from_str(h.action_with(4, 1)[0]["params"]["in"][1]["value"].as_str().unwrap()).unwrap();
    assert_eq!(data["selects"], json!([[7, 3, 0, 3, 1]]));
}

#[tokio::test]
async fn clean_rooms_rejects_unknown_rooms_and_never_starts() {
    let h = Harness::start().await;
    h.inject_rooms();
    let (code, reply) = h.tool("clean_rooms", json!({"rooms": ["garage"]})).await;
    assert_eq!(code, 400);
    let message = reply["error"].as_str().unwrap();
    assert!(message.contains("Unknown room 'garage'") && message.contains("Kitchen (3)"), "{message}");
    let (code, _) = h.tool("clean_rooms", json!({"rooms": []})).await;
    assert_eq!(code, 400);
    assert!(h.action_with(4, 1).is_empty());
}

#[tokio::test]
async fn clean_rooms_switches_the_cleaning_mode_first() {
    let h = Harness::start().await;
    h.inject_rooms();
    h.tool("clean_rooms", json!({"rooms": [7], "mode": "mop"})).await;
    let methods = h.robot.methods();
    let set = methods.iter().position(|m| m == "set_properties").expect("mode must be set");
    let start = methods.iter().rposition(|m| m == "action").expect("cleaning must start");
    assert!(set < start, "the mode has to be set before the job starts");
}

#[tokio::test]
async fn rooms_without_a_xiaomi_sign_in_explain_why() {
    let h = Harness::start().await; // no map injected and no cloud session
    let (code, reply) = h.tool("list_rooms", json!({})).await;
    assert_eq!(code, 400);
    assert!(reply["error"].as_str().unwrap().contains("vacuumd setup"), "{reply}");
}

// MARK: - Driving

#[tokio::test]
async fn driving_is_limited_announced_once_and_always_stops() {
    let h = Harness::start().await;
    let (code, _) = h.tool("drive", json!({"velocity": 5000, "rotation": -999, "duration_ms": 500})).await;
    assert_eq!(code, 200);
    let payloads: Vec<Value> = h
        .robot
        .requests("set_properties")
        .iter()
        .filter(|r| r["params"][0]["siid"] == 4 && r["params"][0]["piid"] == 15)
        .map(|r| serde_json::from_str(r["params"][0]["value"].as_str().unwrap()).unwrap())
        .collect();
    assert!(payloads.len() >= 3, "expected several drive commands, got {}", payloads.len());
    assert_eq!(payloads[0]["spdv"], 600, "speed is capped");
    assert_eq!(payloads[0]["spdw"], -128, "turn rate is capped");
    assert_eq!(payloads[0]["audio"], "true", "the first command announces remote control");
    assert_eq!(payloads[1]["audio"], "false");
    let last = payloads.last().unwrap();
    assert_eq!((last["spdv"].as_i64(), last["spdw"].as_i64()), (Some(0), Some(0)), "it must end by standing still");
    assert_eq!(h.action_with(2, 2).len(), 1, "and leave manual mode");
}

#[tokio::test]
async fn two_drives_at_once_are_refused() {
    let h = Harness::start().await;
    let (first, second) = tokio::join!(h.tool("drive", json!({"velocity": 100, "duration_ms": 600})), async {
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        h.tool("drive", json!({"velocity": 100, "duration_ms": 200})).await
    });
    assert_eq!(first.0, 200);
    assert_eq!(second.0, 400);
    assert!(second.1["error"].as_str().unwrap().contains("already being driven"));
}

#[tokio::test]
async fn drive_requires_a_duration() {
    let h = Harness::start().await;
    let (code, _) = h.tool("drive", json!({"velocity": 100})).await;
    assert_eq!(code, 400);
    assert!(h.robot.requests("set_properties").is_empty());
}

// MARK: - Endpoints for the Mac app

#[tokio::test]
async fn properties_are_served_raw_for_the_app() {
    let h = Harness::start().await;
    let reply: Value = h.http.get(format!("{}/v1/properties", h.base)).bearer_auth(API_TOKEN).send().await.unwrap().json().await.unwrap();
    assert_eq!(reply["online"], true);
    assert_eq!(reply["values"]["2.1"], 13);
    assert_eq!(reply["values"]["3.1"], 87);
    assert!(reply["values"].get("2.2").is_some());
}

#[tokio::test]
async fn raw_miio_passes_through_and_reports_failure_kinds() {
    let h = Harness::start().await;
    let post = |body: Value| h.http.post(format!("{}/v1/miio", h.base)).bearer_auth(API_TOKEN).body(body.to_string()).send();

    let ok: Value = post(json!({"method": "get_properties", "params": [{"did": "x", "siid": 3, "piid": 1}]})).await.unwrap().json().await.unwrap();
    assert_eq!(ok["result"][0]["value"], 87);

    let lost = post(json!({"method": "never", "params": [], "timeout_ms": 200, "retry": false})).await.unwrap();
    assert_eq!(lost.status().as_u16(), 502);
    assert_eq!(lost.json::<Value>().await.unwrap()["kind"], "timeout");

    let refused: Value = post(json!({"method": "bogus", "params": []})).await.unwrap().json().await.unwrap();
    assert_eq!((refused["kind"].as_str(), refused["code"].as_i64()), (Some("device"), Some(-9999)));

    let bad = post(json!({"params": []})).await.unwrap();
    assert_eq!(bad.status().as_u16(), 400);
}

#[tokio::test]
async fn polling_pauses_while_the_app_drives() {
    let h = Harness::start().await;
    h.http
        .post(format!("{}/v1/miio", h.base))
        .bearer_auth(API_TOKEN)
        .body(json!({"method": "set_properties", "params": [], "channel": "drive", "retry": false}).to_string())
        .send()
        .await
        .unwrap();
    let before = h.robot.requests("get_properties").len();
    h.service.refresh().await; // would normally read the robot
    assert_eq!(h.robot.requests("get_properties").len(), before, "status polls must not compete with steering");
}

#[tokio::test]
async fn config_rejects_a_bad_token() {
    let h = Harness::start().await;
    let reply = h
        .http
        .post(format!("{}/v1/config", h.base))
        .bearer_auth(API_TOKEN)
        .body(json!({"robot": {"ip": "1.2.3.4", "token": "nothex", "did": "1"}}).to_string())
        .send()
        .await
        .unwrap();
    assert_eq!(reply.status().as_u16(), 400);
}

// MARK: - MCP and security

#[tokio::test]
async fn mcp_end_to_end() {
    let h = Harness::start().await;
    let init = h.mcp(json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}})).await;
    assert_eq!(init["result"]["serverInfo"]["name"], "vacuumd");
    let list = h.mcp(json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})).await;
    let tools = list["result"]["tools"].as_array().unwrap();
    assert_eq!(tools.len(), 15);
    assert!(tools.iter().all(|t| t["inputSchema"]["type"] == "object" && t["description"].as_str().unwrap().len() > 10));
    assert_eq!(tools.iter().find(|t| t["name"] == "get_status").unwrap()["annotations"]["readOnlyHint"], true);

    let call = h.mcp(json!({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "get_status", "arguments": {"fresh": true}}})).await;
    assert_eq!(call["result"]["isError"], false);
    let text: Value = serde_json::from_str(call["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(text["batteryPercent"], 87);

    let bad = h.mcp(json!({"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "set_suction", "arguments": {"level": "x"}}})).await;
    assert_eq!(bad["result"]["isError"], true);
    let unknown = h.mcp(json!({"jsonrpc": "2.0", "id": 5, "method": "nope"})).await;
    assert_eq!(unknown["error"]["code"], -32601);
    let notification = h
        .http
        .post(format!("{}/mcp", h.base))
        .bearer_auth(API_TOKEN)
        .body(json!({"jsonrpc": "2.0", "method": "notifications/initialized"}).to_string())
        .send()
        .await
        .unwrap();
    assert_eq!(notification.status().as_u16(), 202);
}

#[tokio::test]
async fn requests_without_the_token_or_from_other_sites_are_refused() {
    let h = Harness::start().await;
    let status = |r: reqwest::RequestBuilder| async move { r.send().await.unwrap().status().as_u16() };
    for path in ["/mcp", "/v1/tools/get_status", "/v1/miio", "/v1/config"] {
        assert_eq!(status(h.http.post(format!("{}{path}", h.base))).await, 401, "{path} without a token");
        assert_eq!(status(h.http.post(format!("{}{path}", h.base)).bearer_auth("wrong-wrong-wrong-wrong-wrong-wrong-0")).await, 401);
    }
    assert_eq!(status(h.http.get(format!("{}/v1/properties", h.base))).await, 401);
    let foreign = h.http.post(format!("{}/mcp", h.base)).bearer_auth(API_TOKEN).header("Origin", "https://evil.example");
    assert_eq!(status(foreign).await, 403);
    let rebinding = h.http.post(format!("{}/mcp", h.base)).bearer_auth(API_TOKEN).header("Host", "evil.example");
    assert_eq!(status(rebinding).await, 403);
    assert_eq!(status(h.http.get(format!("{}/health", h.base))).await, 200, "health is public and reveals nothing");
    assert_eq!(h.robot.requests("action").len() + h.robot.requests("set_properties").len(), 0, "refused requests must not touch the robot");
}

#[tokio::test]
async fn without_a_robot_every_tool_explains_what_to_do() {
    isolate_settings();
    let app = App::new(API_TOKEN.into());
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(server::serve_on(listener, app));
    let reply = reqwest::Client::new()
        .post(format!("{base}/mcp"))
        .bearer_auth(API_TOKEN)
        .body(json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "go_home", "arguments": {}}}).to_string())
        .send()
        .await
        .unwrap()
        .json::<Value>()
        .await
        .unwrap();
    assert_eq!(reply["result"]["isError"], true);
    assert!(reply["result"]["content"][0]["text"].as_str().unwrap().contains("No robot is set up"));
}

// MARK: - Map retries

#[tokio::test]
async fn a_failed_map_read_is_retried_until_it_works() {
    use crate::service::{retrying, MapFailure};
    use crate::service::ToolError;
    use std::sync::atomic::{AtomicUsize, Ordering};
    let attempts = AtomicUsize::new(0);
    let delays = [std::time::Duration::from_millis(1); 3];
    let result = retrying(&delays, || async {
        match attempts.fetch_add(1, Ordering::SeqCst) {
            0 | 1 => Err(MapFailure::Retry(ToolError::new("corrupt deflate stream"))),
            _ => Ok("map"),
        }
    })
    .await;
    assert!(matches!(result, Ok("map")));
    assert_eq!(attempts.load(Ordering::SeqCst), 3);
}

#[tokio::test]
async fn map_retries_give_up_and_never_retry_an_expired_sign_in() {
    use crate::service::{retrying, MapFailure, ToolError};
    use std::sync::atomic::{AtomicUsize, Ordering};
    let delays = [std::time::Duration::from_millis(1); 3];

    let always_bad = AtomicUsize::new(0);
    let result: Result<(), _> = retrying(&delays, || async {
        always_bad.fetch_add(1, Ordering::SeqCst);
        Err(MapFailure::Retry(ToolError::new("still corrupt")))
    })
    .await;
    assert!(result.is_err());
    assert_eq!(always_bad.load(Ordering::SeqCst), 4, "one try plus three retries");

    let expired = AtomicUsize::new(0);
    let result: Result<(), _> = retrying(&delays, || async {
        expired.fetch_add(1, Ordering::SeqCst);
        Err(MapFailure::Fatal(ToolError::new("sign-in expired")))
    })
    .await;
    assert!(result.is_err());
    assert_eq!(expired.load(Ordering::SeqCst), 1, "retrying can't fix an expired sign-in");
}

// MARK: - Map picture

#[tokio::test]
async fn the_map_is_saved_as_a_png_and_the_path_is_returned() {
    let h = Harness::start().await;
    h.inject_rooms();
    let (code, reply) = h.tool("get_map_image", json!({"fresh": false})).await;
    assert_eq!(code, 200, "{reply}");
    let path = std::path::PathBuf::from(reply["path"].as_str().unwrap());
    assert!(path.starts_with(std::env::var("VACUUMD_MAP_DIR").unwrap()), "saved in the pictures folder");
    let bytes = std::fs::read(&path).unwrap();
    assert_eq!(&bytes[..8], b"\x89PNG\r\n\x1a\n");
    assert_eq!(reply["width"].as_u64().unwrap() as usize > 0, true);
    let legend = reply["legend"].as_array().unwrap();
    assert_eq!(legend.iter().map(|l| l["id"].as_u64().unwrap()).collect::<Vec<_>>(), [3, 5, 7]);
    assert_eq!(legend[0]["name"], "Kitchen");
    assert!(reply["message"].as_str().unwrap().contains("file path"));
}

#[tokio::test]
async fn an_unreadable_map_falls_back_to_the_last_one_and_says_how_old_it_is() {
    let h = Harness::start().await; // no Xiaomi sign-in: a new download is impossible
    h.inject_rooms();
    let (code, reply) = h.tool("get_map_image", json!({"fresh": true})).await;
    assert_eq!(code, 200, "{reply}");
    assert!(reply["mapAgeSeconds"].is_u64());
}

#[tokio::test]
async fn without_any_map_the_picture_explains_what_is_missing() {
    let h = Harness::start().await;
    let (code, reply) = h.tool("get_map_image", json!({})).await;
    assert_eq!(code, 400);
    assert!(reply["error"].as_str().unwrap().contains("vacuumd setup"));
}

#[test]
fn only_the_newest_pictures_are_kept() {
    let dir = std::env::temp_dir().join(format!("vacuumd-prune-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    for day in 1..=14 {
        std::fs::write(dir.join(format!("vacuum-map-202610{day:02}-120000.png")), b"x").unwrap();
    }
    std::fs::write(dir.join("notes.txt"), b"mine").unwrap();
    crate::config::keep_newest_map_images(&dir, 10);
    let mut left: Vec<String> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().to_string()).collect();
    left.sort();
    assert_eq!(left.len(), 11, "10 pictures plus an unrelated file that must never be deleted");
    assert!(left.contains(&"notes.txt".to_string()));
    assert!(!left.iter().any(|n| n.contains("20261001")), "the oldest are removed");
    assert!(left.iter().any(|n| n.contains("20261014")));
}

// MARK: - Room editing

fn room_edit_payload(h: &Harness) -> Value {
    let edits = h.action_with(6, 2);
    assert_eq!(edits.len(), 1, "exactly one room edit should be sent");
    let input = &edits[0]["params"]["in"][0];
    assert_eq!(input["piid"], 4);
    serde_json::from_str(input["value"].as_str().unwrap()).unwrap()
}

#[tokio::test]
async fn a_merge_without_confirm_only_shows_a_picture() {
    let h = Harness::start().await;
    h.inject_rooms();
    let (code, reply) = h.tool("merge_rooms", json!({"rooms": [3, 5]})).await;
    assert_eq!(code, 200, "{reply}");
    assert_eq!(reply["preview"], true);
    assert_eq!(reply["nothingWasChanged"], true);
    assert!(std::path::Path::new(reply["picture"].as_str().unwrap()).exists());
    assert!(reply["next"].as_str().unwrap().contains("confirm: true"));
    assert!(h.action_with(6, 2).is_empty(), "a preview must never reach the robot");
}

#[tokio::test]
async fn a_confirmed_merge_sends_the_exact_command_and_reports_the_new_state() {
    let h = Harness::start().await;
    h.inject_rooms();
    let (code, reply) = h.tool("merge_rooms", json!({"rooms": [5, 3], "confirm": true})).await;
    assert_eq!(code, 200, "{reply}");
    assert_eq!(room_edit_payload(&h), json!({"msr": [3, 5], "mapid": 12}), "sorted, with the saved map id");
    assert_eq!(reply["ok"], true);
    let warnings = reply["warnings"].to_string();
    assert!(warnings.contains("Room numbers may have changed") && warnings.contains("Hidden rooms"), "{warnings}");
    // Without a Xiaomi sign-in the new list can't be downloaded; that is said, not hidden.
    assert!(reply["rooms"].is_null() && warnings.contains("call list_rooms"), "{reply}");
}

#[tokio::test]
async fn merging_rooms_that_do_not_touch_or_do_not_exist_is_refused() {
    let h = Harness::start().await;
    h.inject_rooms();
    let (code, reply) = h.tool("merge_rooms", json!({"rooms": [3, 7], "confirm": true})).await;
    assert_eq!(code, 400);
    assert!(reply["error"].as_str().unwrap().contains("don't touch"), "{reply}");
    let (code, reply) = h.tool("merge_rooms", json!({"rooms": [3, 99], "confirm": true})).await;
    assert_eq!(code, 400);
    assert!(reply["error"].as_str().unwrap().contains("no room 99"));
    let (code, _) = h.tool("merge_rooms", json!({"rooms": [3, 3], "confirm": true})).await;
    assert_eq!(code, 400);
    let (code, _) = h.tool("merge_rooms", json!({"rooms": [3]})).await;
    assert_eq!(code, 400);
    assert!(h.action_with(6, 2).is_empty(), "nothing invalid may reach the robot");
}

#[tokio::test]
async fn dividing_extends_the_line_across_the_room_and_converts_meters() {
    let h = Harness::start().await;
    h.inject_rooms();
    // Room 5 spans x 200..500 mm, y 0..100 mm. A horizontal line at y = 0.05 m, from x 0.2 m to 0.5 m.
    let (code, reply) = h.tool("divide_room", json!({"room": 5, "from": {"x": 0.2, "y": 0.05}, "to": {"x": 0.5, "y": 0.05}, "confirm": true})).await;
    assert_eq!(code, 200, "{reply}");
    // Stretched over the room plus 300 mm each side: x from -100 to 800.
    assert_eq!(room_edit_payload(&h), json!({"dsrid": [-100, 50, 800, 50, 5], "mapid": 12}));
}

#[tokio::test]
async fn a_division_preview_draws_the_line_and_sends_nothing() {
    let h = Harness::start().await;
    h.inject_rooms();
    let (code, reply) = h.tool("divide_room", json!({"room": 5, "from": {"x": 0.2, "y": 0.05}, "to": {"x": 0.5, "y": 0.05}})).await;
    assert_eq!(code, 200, "{reply}");
    assert_eq!(reply["preview"], true);
    assert!(std::fs::metadata(reply["picture"].as_str().unwrap()).unwrap().len() > 100);
    assert!(h.action_with(6, 2).is_empty());
}

#[tokio::test]
async fn bad_dividing_lines_are_refused_before_the_robot_hears_about_them() {
    let h = Harness::start().await;
    h.inject_rooms();
    let (code, reply) = h.tool("divide_room", json!({"room": 5, "from": {"x": 0.2, "y": 0.05}, "to": {"x": 0.3, "y": 0.05}, "confirm": true})).await;
    assert_eq!(code, 400);
    assert!(reply["error"].as_str().unwrap().contains("at least 0.3 m"));
    let (code, _) = h.tool("divide_room", json!({"room": 5, "from": {"x": 0.2}, "to": {"x": 0.5, "y": 0.05}, "confirm": true})).await;
    assert_eq!(code, 400);
    let (code, _) = h.tool("divide_room", json!({"room": 42, "from": {"x": 0, "y": 0}, "to": {"x": 1, "y": 0}, "confirm": true})).await;
    assert_eq!(code, 400);
    assert!(h.action_with(6, 2).is_empty());
}

#[tokio::test]
async fn a_refusal_from_the_robot_is_reported_and_nothing_is_assumed() {
    let h = Harness::start().await;
    h.inject_rooms();
    h.robot.action_replies.lock().unwrap().insert((6, 2), json!({"code": 0, "out": [{"piid": 6, "value": 7}]}));
    let (code, reply) = h.tool("merge_rooms", json!({"rooms": [3, 5], "confirm": true})).await;
    assert_eq!(code, 400);
    let message = reply["error"].as_str().unwrap();
    assert!(message.contains("didn't accept") && message.contains("code 7") && message.contains("Nothing was changed"), "{message}");
}

#[tokio::test]
async fn a_room_edit_through_the_raw_channel_makes_the_server_forget_its_map() {
    let h = Harness::start().await;
    h.inject_rooms();
    let (code, _) = h.tool("list_rooms", json!({})).await;
    assert_eq!(code, 200, "the injected map is served");
    // The Mac app edits rooms through /v1/miio; the next room list must not come from the old map.
    h.http
        .post(format!("{}/v1/miio", h.base))
        .bearer_auth(API_TOKEN)
        .body(json!({"method": "action", "params": {"did": "6.2", "siid": 6, "aiid": 2, "in": [{"piid": 4, "value": "{}"}]}}).to_string())
        .send()
        .await
        .unwrap();
    let (code, reply) = h.tool("list_rooms", json!({})).await;
    assert_eq!(code, 400, "the cached map was dropped, and there's no Xiaomi sign-in to download another");
    assert!(reply["error"].as_str().unwrap().contains("vacuumd setup"));
}

#[tokio::test]
async fn rooms_say_where_they_are_in_meters_and_the_ruler_is_optional() {
    let h = Harness::start().await;
    h.inject_rooms();
    let (_, rooms) = h.tool("list_rooms", json!({})).await;
    let five = rooms.as_array().unwrap().iter().find(|r| r["id"] == 5).unwrap();
    assert_eq!(five["boundsM"], json!([0.2, 0.0, 0.5, 0.1]));
    let (_, plain) = h.tool("get_map_image", json!({"fresh": false})).await;
    let (_, ruled) = h.tool("get_map_image", json!({"fresh": false, "grid": true})).await;
    assert_ne!(plain["path"], ruled["path"], "two pictures never share a file");
    assert!(std::fs::read(plain["path"].as_str().unwrap()).unwrap() != std::fs::read(ruled["path"].as_str().unwrap()).unwrap(), "the ruler changes the picture");
    assert_eq!(ruled["legend"][1]["boundsM"], json!([0.2, 0.0, 0.5, 0.1]));
}
