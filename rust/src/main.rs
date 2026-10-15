//! vacuumd — control your robot vacuum from the Vacuum app and from AI agents (MCP).
mod cloud;
mod config;
mod crypto;
mod errors;
mod install;
mod audit;
mod map;
mod miio;
mod policy;
mod server;
mod service;
mod render;
mod spec;
mod tools;
#[cfg(test)]
mod e2e;

use serde_json::{json, Value};
use std::io::{BufRead, Write};

const DEFAULT_PORT: u16 = 47231;

fn port() -> u16 {
    std::env::var("VACUUMD_PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(DEFAULT_PORT)
}

fn fail(message: &str) -> ! {
    eprintln!("vacuumd: {message}");
    std::process::exit(1)
}

const HELP: &str = "vacuumd — control your robot vacuum from AI agents (MCP) and the Vacuum app

  vacuumd setup       sign in to Xiaomi once and find your robot (no password is typed here)
  vacuumd install     run in the background at login, and show how to connect an agent
  vacuumd uninstall   stop and remove the background service
  vacuumd serve       run in the foreground (what the background service does)
  vacuumd mcp         MCP over stdio, for clients that start a command (talks to the running server)
  vacuumd status      is it running? is the robot reachable?
  vacuumd audit [N]   what agents and the app asked the robot to do (last N entries, default 30)
  vacuumd map-folder [private|pictures|<folder>]   where map pictures are saved (default: private)
  vacuumd logout      forget the Xiaomi sign-in, the robot's token and both access tokens, and stop vacuumd
  vacuumd version     print the version
  vacuumd call TOOL [JSON]   run one tool from the command line, e.g. vacuumd call get_status
  vacuumd token [app] print the agents' access token (with 'app': the Mac app's)
";

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("serve") => serve().await,
        Some("setup") => setup(&args[1..]).await,
        Some("install") => do_install(),
        Some("uninstall") => {
            install::uninstall();
            println!("vacuumd removed. Your robot settings were left alone.");
        }
        Some("status") => status().await,
        Some("version") | Some("--version") | Some("-V") => println!("vacuumd {}", env!("CARGO_PKG_VERSION")),
        Some("mcp") => bridge().await,
        Some("call") => call(&args[1..]).await,
        Some("token") => {
            let token = if args.get(1).map(String::as_str) == Some("app") { config::app_token() } else { config::mcp_token() };
            println!("{}", token.unwrap_or_else(|e| fail(&e.to_string())));
        }
        Some("audit") => show_audit(args.get(1).and_then(|n| n.parse().ok()).unwrap_or(30)),
        Some("map-folder") => map_folder(args.get(1).map(String::as_str)),
        Some("logout") => logout().await,
        _ => print!("{HELP}"),
    }
}

async fn serve() {
    let app_token = config::app_token().unwrap_or_else(|e| fail(&e.to_string()));
    let mcp_token = config::mcp_token().unwrap_or_else(|e| fail(&e.to_string()));
    let app = server::App::new(app_token, mcp_token);
    // Keeps running without a robot: the Vacuum app (or `vacuumd setup`) can provide the settings later.
    match app.reload() {
        Ok(()) => println!("listening on 127.0.0.1:{}, robot {}", port(), config::robot().map(|r| r.ip).unwrap_or_default()),
        Err(e) => println!("listening on 127.0.0.1:{} — {}", port(), e.0),
    }
    tokio::select! {
        result = server::serve(port(), app.clone()) => {
            if let Err(e) = result {
                fail(&format!("couldn't listen on port {}: {e}", port()));
            }
        }
        _ = app.shutdown.notified() => println!("stopping: asked to shut down"),
    }
}

fn do_install() {
    let binary = install::install(port()).unwrap_or_else(|e| fail(&e));
    let path_note = install::add_to_path();
    // The agent starts `vacuumd mcp` itself and that reads the access token on its own,
    // so no secret has to be pasted into an agent's settings.
    println!(
        "vacuumd is installed and starts at login. Log: {}\n{path_note}\n\nConnect an agent:\n\n  Claude Code:\n    claude mcp add vacuum -- \"{}\" mcp\n\n  Claude Desktop, Cursor and other agents — add this to their MCP settings:\n    {}\n\nThen restart the agent and ask it for the robot's status.\n(Agents that only accept a URL can use http://127.0.0.1:{}/mcp with an \"Authorization: Bearer <vacuumd token>\" header.)",
        config::data_dir().join("vacuumd.log").display(),
        binary.display(),
        serde_json::to_string_pretty(&json!({"mcpServers": {"vacuum": {"command": binary.to_string_lossy(), "args": ["mcp"]}}})).unwrap(),
        port()
    );
}

// MARK: - setup

async fn setup(args: &[String]) {
    let flag = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    // Manual path: you already know the robot's address and token.
    if let (Some(ip), Some(token)) = (flag("--ip"), flag("--token")) {
        let robot = config::RobotConfig { ip, token, did: flag("--did").unwrap_or_default() };
        if hex::decode(&robot.token).map(|b| b.len()) != Ok(16) {
            fail("--token must be 32 hex characters");
        }
        config::save_robot(&robot).unwrap_or_else(|e| fail(&e.to_string()));
        println!("Saved. Room names also need a Xiaomi sign-in: run `vacuumd setup` without options.");
        return;
    }

    let login = cloud::QrLogin::new();
    let start = login.start().await.unwrap_or_else(|e| fail(&e.to_string()));
    println!("Sign in to your Xiaomi account to find your robot (nothing is typed into this program):\n");
    if let Some(url) = &start.web_login_url {
        println!("  Open this page in a browser and sign in:\n    {url}\n");
    }
    println!("  Or scan this QR code image with the Xiaomi Home app:\n    {}\n", start.qr_image_url);
    println!("Waiting for you to finish (up to {} minutes)...", start.timeout.as_secs() / 60);
    let session = login.wait_for_confirmation(&start, "de").await.unwrap_or_else(|e| fail(&e.to_string()));
    println!("Signed in. Looking for your robot on each Xiaomi region...");

    let mut found: Vec<(cloud::CloudSession, cloud::CloudDevice)> = vec![];
    for (region, name) in cloud::REGIONS {
        let regional = cloud::CloudSession { server: region.to_string(), ..session.clone() };
        match cloud::XiaomiCloud::new(regional.clone()).devices().await {
            Ok(devices) => {
                for device in devices.into_iter().filter(|d| d.is_vacuum()) {
                    println!("  {name}: {} ({}){}", device.name, device.model, if device.is_supported() { "" } else { "  — not supported" });
                    if device.is_supported() {
                        found.push((regional.clone(), device));
                    }
                }
            }
            Err(_) => continue,
        }
    }
    let Some((regional, device)) = found.into_iter().next() else {
        fail(&format!("No {} found on this account.", cloud::SUPPORTED_MODEL))
    };
    let ip = flag("--ip").unwrap_or(device.local_ip.clone());
    if ip.is_empty() {
        fail("The robot's address isn't known to Xiaomi. Run again with --ip <address> (see your router's device list).");
    }
    let robot = config::RobotConfig { ip: ip.clone(), token: device.token, did: device.did };
    config::save_robot(&robot).unwrap_or_else(|e| fail(&e.to_string()));
    config::save_cloud(&regional).unwrap_or_else(|e| fail(&e.to_string()));
    println!("\nFound your robot: {} at {ip}.", device.name);
    println!("Saved your robot and Xiaomi sign-in in {} (readable only by you).\n", config::data_dir().display());
    if tell_running_server(&robot, &regional).await {
        println!("vacuumd is running and is now connected to your robot. You're ready to use it.\n");
        println!("Optional: run `vacuumd install` to also start it at every login.");
        println!("Without it, vacuumd stops when you restart your computer or stop it.");
    } else {
        println!("vacuumd isn't running yet. Choose how to start it:\n");
        println!("  vacuumd install   runs in the background and starts at every login (recommended)");
        println!("  vacuumd serve     runs only in this terminal, until you close it");
    }
}



/// If vacuumd is already running, hands it the new settings so it doesn't need a restart.
async fn tell_running_server(robot: &config::RobotConfig, cloud: &cloud::CloudSession) -> bool {
    let Ok(token) = config::app_token() else { return false };
    let body = json!({"robot": robot, "cloud": cloud});
    match reqwest::Client::new().post(format!("{}/v1/config", base_url())).bearer_auth(token).body(body.to_string()).send().await {
        Ok(response) => response.status().is_success(),
        Err(_) => false,
    }
}

/// Prints whether vacuumd is running and what the robot is doing. Exits with 1 when it isn't running.
async fn status() {
    let client = reqwest::Client::builder().timeout(std::time::Duration::from_secs(10)).build().unwrap();
    let running = client.get(format!("{}/health", base_url())).send().await.map_or(false, |r| r.status().is_success());
    let login = if install::starts_at_login() { "yes" } else { "no (run `vacuumd install` to enable)" };
    if !running {
        println!("vacuumd is not running.");
        println!("Starts at login: {login}");
        println!("Start it with `vacuumd install` (background, at every login) or `vacuumd serve` (this terminal only).");
        std::process::exit(1);
    }
    println!("vacuumd is running (port {}).", port());
    println!("Starts at login: {login}");
    if config::robot().is_none() {
        println!("Robot: not set up yet. Run `vacuumd setup`.");
        return;
    }
    let token = config::mcp_token().unwrap_or_else(|e| fail(&e.to_string()));
    let reply = client.post(format!("{}/v1/tools/get_status", base_url())).bearer_auth(token).send().await;
    match reply.ok().filter(|r| r.status().is_success()) {
        Some(response) => {
            let s: Value = response.json().await.unwrap_or(Value::Null);
            if s["online"] == true {
                let battery = s["batteryPercent"].as_i64().map(|b| format!(" · {b}%")).unwrap_or_default();
                let fault = s["fault"]["description"].as_str().map(|f| format!(" · fault: {f}")).unwrap_or_default();
                println!("Robot: online · {}{battery}{fault}", s["state"].as_str().unwrap_or("unknown state"));
            } else {
                println!("Robot: not reachable — {}", s["error"].as_str().unwrap_or("no answer"));
            }
        }
        None => println!("Robot: couldn't read its status."),
    }
}

// MARK: - privacy commands

fn show_audit(count: usize) {
    let entries = audit::recent(count);
    if entries.is_empty() {
        println!("Nothing recorded yet. (Reading the robot's status isn't recorded; everything that changes something is.)");
        return;
    }
    for e in entries {
        let text = |key: &str| e[key].as_str().unwrap_or("").to_string();
        let what = match text("event").as_str() {
            "tool" => format!("{} {}{}", text("tool"), if e["args"].as_object().map_or(true, |a| a.is_empty()) { String::new() } else { e["args"].to_string() },
                if e["ok"] == true { String::new() } else { format!("  FAILED: {}", text("error")) }),
            "raw" => format!("the app sent {}", text("what")),
            "denied" => format!("REFUSED ({}) {} {}", text("reason"), text("path"), text("what")),
            other => other.to_string(),
        };
        let who = if e["as"].is_string() { format!("{} via {}", text("as"), text("via")) } else { text("via") };
        println!("{}  {:<18} {}", text("time"), who, what);
    }
}

fn map_folder(value: Option<&str>) {
    match value {
        None => {
            println!("Map pictures are saved in: {}", config::map_images_dir().path.display());
            println!("Change it with: vacuumd map-folder private | pictures | <folder>");
        }
        Some(choice) => {
            config::set_map_folder(choice).unwrap_or_else(|e| fail(&e.to_string()));
            println!("Map pictures will be saved in: {}", config::map_images_dir().path.display());
            if choice == "pictures" {
                println!("Note: Pictures is often backed up to the cloud (OneDrive, iCloud). A map shows the layout of your home.");
            }
        }
    }
}

/// Removes what lets anyone act as you: the Xiaomi sign-in, the robot's token and both access tokens; stops vacuumd.
/// Room names, furniture and history are left alone.
async fn logout() {
    // Stop the background copy first (otherwise it would start again by itself), then any copy run by hand.
    // (A copy running with another settings folder, like in tests, has its own service: leave the real one alone.)
    if std::env::var_os("VACUUMD_DIR").is_none() {
        install::stop_service();
    }
    if let Ok(token) = config::app_token() {
        let _ = reqwest::Client::new().post(format!("{}/v1/shutdown", base_url())).bearer_auth(token).timeout(std::time::Duration::from_secs(3)).send().await;
    }
    let gone = config::forget_credentials(&config::data_dir());
    audit::record(json!({"event": "logout", "via": "cli", "removed": gone}));
    if gone.is_empty() {
        println!("Nothing was stored.");
    } else {
        println!("Removed: {}", gone.join(", "));
    }
    println!("vacuumd is stopped. Settings like room names and furniture were kept.");
    println!("The Mac app keeps no copy of its own: it asks vacuumd. (Very old app versions may have left one in the Keychain: search for \"com.lubarino.vacuum\" in Keychain Access.)");
    println!("To use vacuumd again: `vacuumd setup`, then `vacuumd install`.");
}

// MARK: - clients of the running server

fn base_url() -> String {
    format!("http://127.0.0.1:{}", port())
}

async fn call(args: &[String]) {
    let Some(tool) = args.first() else { fail("usage: vacuumd call TOOL [JSON]") };
    let token = config::mcp_token().unwrap_or_else(|e| fail(&e.to_string()));
    let body = args.get(1).cloned().unwrap_or_else(|| "{}".into());
    let response = reqwest::Client::new()
        .post(format!("{}/v1/tools/{tool}", base_url()))
        .bearer_auth(token)
        .body(body)
        .send()
        .await
        .unwrap_or_else(|e| fail(&format!("vacuumd isn't running ({e}). Run `vacuumd install`.")));
    let text = response.text().await.unwrap_or_default();
    match serde_json::from_str::<Value>(&text) {
        Ok(value) => println!("{}", serde_json::to_string_pretty(&value).unwrap()),
        Err(_) => println!("{text}"),
    }
}

/// Reads JSON-RPC messages from stdin (one per line) and relays them to the running server.
async fn bridge() {
    let token = config::mcp_token().unwrap_or_else(|e| fail(&e.to_string()));
    let client = reqwest::Client::builder().timeout(std::time::Duration::from_secs(60)).build().unwrap();
    let (tx, mut rx) = tokio::sync::mpsc::channel::<String>(16);
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines().map_while(Result::ok) {
            if !line.trim().is_empty() && tx.blocking_send(line).is_err() {
                break;
            }
        }
    });
    while let Some(line) = rx.recv().await {
        let reply = client.post(format!("{}/mcp", base_url())).bearer_auth(&token).header("Content-Type", "application/json").body(line.clone()).send().await;
        let output = match reply {
            Ok(response) if response.status().as_u16() == 202 => continue, // notification: no reply
            Ok(response) => response.text().await.ok().filter(|t| !t.is_empty()),
            Err(e) => {
                // Only requests (with an id) need an answer.
                let id = serde_json::from_str::<Value>(&line).ok().and_then(|m| m.get("id").cloned());
                id.map(|id| json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32000, "message": format!("vacuumd isn't running ({e}). Run `vacuumd install`.")}}).to_string())
            }
        };
        if let Some(output) = output {
            println!("{}", output.replace('\n', " "));
            let _ = std::io::stdout().flush();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_hosts_only() {
        assert!(server::is_local_host(Some("127.0.0.1:47231")));
        assert!(server::is_local_host(Some("localhost")));
        assert!(!server::is_local_host(Some("evil.example")));
        assert!(!server::is_local_host(None));
        assert!(server::is_local_origin("http://localhost:3000"));
        assert!(!server::is_local_origin("https://evil.example"));
    }

    #[test]
    fn http_parser_waits_for_the_whole_body() {
        let head = "POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\n";
        assert!(matches!(server::parse(format!("{head}ab").as_bytes()), server::Parsed::Incomplete));
        match server::parse(format!("{head}abcde").as_bytes()) {
            server::Parsed::Complete(r) => assert_eq!(r.body, b"abcde"),
            _ => panic!("should parse"),
        }
    }

    #[test]
    fn the_tool_list_is_stable() {
        let names: Vec<_> = tools::list().into_iter().map(|t| t.name).collect();
        assert_eq!(names, ["get_status", "start_cleaning", "stop_cleaning", "go_home", "locate", "empty_bin", "set_suction", "set_mop_level", "set_cleaning_mode", "list_rooms", "get_map_image", "merge_rooms", "divide_room", "clean_rooms", "drive"]);
    }
}
