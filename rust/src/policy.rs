//! What may be asked of the robot through the app's raw channel, and which settings are accepted.
//! The raw channel and the settings endpoint exist for the Mac app only. Limiting them to what the app
//! really uses means a stolen app token can't be turned into arbitrary robot commands, or into a way to
//! make vacuumd talk to someone else's server.
use crate::cloud::{CloudSession, REGIONS};
use crate::config::RobotConfig;
use crate::spec;
use serde_json::Value;
use std::net::{IpAddr, SocketAddr};

/// Settings the Mac app writes: suction, mop water, cleaning mode, manual driving, schedules.
const ALLOWED_SETS: [spec::Prop; 5] = [spec::SUCTION, spec::MOP_LEVEL, spec::CLEAN_SETTING, spec::REMOTE_CONTROL, spec::SCHEDULES];

/// Actions the Mac app sends: start/stop, empty bin, go home, locate, delete a schedule, reset a part's life,
/// ask for the map, edit rooms and zones, clean chosen rooms.
const ALLOWED_ACTIONS: [spec::Action; 13] = [
    spec::START_CLEANING, spec::STOP_CLEANING, spec::EMPTY_BIN, spec::GO_HOME, spec::LOCATE, spec::START_CUSTOM_CLEAN,
    (8, 1),  // delete a schedule
    (9, 1),  // reset main brush
    (10, 1), // reset side brush
    (11, 1), // reset filter
    (18, 1), // reset mop pads
    spec::REQUEST_MAP,
    (6, 2),  // room and zone edits
];

fn key(item: &Value) -> Option<(u32, u32)> {
    Some((item["siid"].as_u64()? as u32, item["piid"].as_u64()? as u32))
}

/// Ok if the app may send this robot request; otherwise a message saying what isn't allowed.
pub fn check_raw(method: &str, params: &Value) -> Result<(), String> {
    match method {
        "get_properties" | "set_properties" => {
            let items = params.as_array().ok_or("The request must list properties.")?;
            if items.len() > 30 {
                return Err("Too many properties in one request.".into());
            }
            for item in items {
                let property = key(item).ok_or("Each property needs a siid and a piid.")?;
                let allowed = if method == "get_properties" { spec::POLLED.contains(&property) } else { ALLOWED_SETS.contains(&property) };
                if !allowed {
                    return Err(format!("{method} on property {}.{} isn't allowed.", property.0, property.1));
                }
            }
            Ok(())
        }
        "action" => {
            let siid = params["siid"].as_u64().ok_or("An action needs a siid and an aiid.")? as u32;
            let aiid = params["aiid"].as_u64().ok_or("An action needs a siid and an aiid.")? as u32;
            if ALLOWED_ACTIONS.contains(&(siid, aiid)) { Ok(()) } else { Err(format!("Action {siid}.{aiid} isn't allowed.")) }
        }
        other => Err(format!("The robot method '{other}' isn't allowed.")),
    }
}

/// True for an address inside a home network: private, loopback, link-local, or Tailscale-style shared ranges.
/// Host names are refused: the robot is found by address.
pub fn is_home_address(address: &str) -> bool {
    let host = match address.parse::<SocketAddr>() {
        Ok(socket) => socket.ip(),
        Err(_) => match address.parse::<IpAddr>() {
            Ok(ip) => ip,
            Err(_) => return false,
        },
    };
    match host {
        IpAddr::V4(ip) => ip.is_private() || ip.is_loopback() || ip.is_link_local() || (ip.octets()[0] == 100 && (64..128).contains(&ip.octets()[1])),
        IpAddr::V6(ip) => {
            let first = ip.segments()[0];
            ip.is_loopback() || (first & 0xfe00) == 0xfc00 || (first & 0xffc0) == 0xfe80
        }
    }
}

pub fn validate_robot(robot: &RobotConfig) -> Result<(), String> {
    if hex::decode(&robot.token).map(|b| b.len()) != Ok(16) {
        return Err("The robot token must be 32 hex characters.".into());
    }
    if !is_home_address(&robot.ip) {
        return Err("The robot's address must be an IP address on your home network (like 192.168.1.20).".into());
    }
    if robot.did.len() > 40 || !robot.did.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
        return Err("The robot's device id looks wrong.".into());
    }
    Ok(())
}

pub fn validate_cloud(cloud: &CloudSession) -> Result<(), String> {
    if !REGIONS.iter().any(|(code, _)| *code == cloud.server) {
        return Err(format!("Unknown Xiaomi region '{}'.", cloud.server));
    }
    let reasonable = |s: &str| !s.is_empty() && s.len() <= 1024 && !s.chars().any(|c| c.is_control());
    if !cloud.user_id.chars().all(|c| c.is_ascii_digit()) || !reasonable(&cloud.user_id) || !reasonable(&cloud.ssecurity) || !reasonable(&cloud.service_token) || !reasonable(&cloud.agent) {
        return Err("The Xiaomi sign-in looks wrong.".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn robot(ip: &str) -> RobotConfig {
        RobotConfig { ip: ip.into(), token: "ab".repeat(16), did: "12345".into() }
    }

    #[test]
    fn everything_the_mac_app_sends_is_allowed() {
        // set_properties: suction, mop water, cleaning mode, manual driving, schedules
        for (siid, piid) in [(2, 3), (4, 5), (4, 23), (4, 15), (8, 2)] {
            assert!(check_raw("set_properties", &json!([{"did": "x", "siid": siid, "piid": piid, "value": 1}])).is_ok(), "{siid}.{piid}");
        }
        // actions: every one the app has a button for
        for (siid, aiid) in [(2, 1), (2, 2), (2, 4), (3, 1), (7, 1), (4, 1), (8, 1), (9, 1), (10, 1), (11, 1), (18, 1), (6, 1), (6, 2)] {
            assert!(check_raw("action", &json!({"did": "x", "siid": siid, "aiid": aiid, "in": []})).is_ok(), "{siid}.{aiid}");
        }
        assert!(check_raw("get_properties", &json!([{"did": "x", "siid": 3, "piid": 1}])).is_ok());
    }

    #[test]
    fn anything_else_is_refused() {
        for (method, params) in [
            ("set_properties", json!([{"siid": 2, "piid": 1, "value": 3}])),   // the robot's state
            ("set_properties", json!([{"siid": 1, "piid": 1, "value": 3}])),   // device information
            ("get_properties", json!([{"siid": 1, "piid": 4}])),               // not something the app reads
            ("action", json!({"siid": 1, "aiid": 1})),                          // restart-style actions
            ("action", json!({"siid": 99, "aiid": 1})),
            ("miIO.ota", json!({})),                                            // firmware update
            ("miIO.config_router", json!({"ssid": "x", "passwd": "y"})),       // move it to another network
            ("set_properties", json!("not a list")),
            ("action", json!({"aiid": 1})),
        ] {
            assert!(check_raw(method, &params).is_err(), "{method} {params} should be refused");
        }
        // one bad item spoils the whole request
        let mixed = json!([{"siid": 2, "piid": 3, "value": 1}, {"siid": 2, "piid": 1, "value": 3}]);
        assert!(check_raw("set_properties", &mixed).is_err());
    }

    #[test]
    fn only_home_network_addresses_are_accepted_for_the_robot() {
        for ok in ["192.168.1.20", "10.0.0.5", "172.16.4.9", "172.31.255.1", "169.254.1.1", "127.0.0.1", "127.0.0.1:54321", "100.64.0.7", "fd12:3456::1", "fe80::1", "::1"] {
            assert!(is_home_address(ok), "{ok} should be accepted");
        }
        for bad in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "1.2.3.4:54321", "example.com", "robot.local", "192.168.1.20.evil.com", "", "2001:4860:4860::8888", "http://192.168.1.2"] {
            assert!(!is_home_address(bad), "{bad} should be refused");
        }
    }

    #[test]
    fn robot_settings_are_checked() {
        assert!(validate_robot(&robot("192.168.1.50")).is_ok());
        assert!(validate_robot(&robot("8.8.8.8")).is_err());
        assert!(validate_robot(&RobotConfig { token: "nothex".into(), ..robot("192.168.1.2") }).is_err());
        assert!(validate_robot(&RobotConfig { did: "x; rm -rf /".into(), ..robot("192.168.1.2") }).is_err());
        assert!(validate_robot(&RobotConfig { did: String::new(), ..robot("192.168.1.2") }).is_ok(), "manual setup may skip the id");
    }

    #[test]
    fn xiaomi_sign_in_values_are_checked() {
        let good = CloudSession { server: "de".into(), user_id: "12345".into(), ssecurity: "abc".into(), service_token: "def".into(), agent: "app".into() };
        assert!(validate_cloud(&good).is_ok());
        assert!(validate_cloud(&CloudSession { server: "evil.example".into(), ..good.clone() }).is_err(), "only Xiaomi's regions");
        assert!(validate_cloud(&CloudSession { user_id: "12a".into(), ..good.clone() }).is_err());
        assert!(validate_cloud(&CloudSession { ssecurity: "a\nb".into(), ..good.clone() }).is_err());
        assert!(validate_cloud(&CloudSession { service_token: "x".repeat(5000), ..good }).is_err());
    }
}
