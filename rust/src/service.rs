//! Owns the one connection to the robot: polls it, runs commands, drives it, and knows the rooms.
use crate::cloud::{CloudSession, XiaomiCloud};
use crate::config::{self, MapFolder, RobotConfig};
use crate::map::{self, VacuumMap};
use crate::miio::{MiioClient, MiioError};
use crate::spec::{self, Action, Mode, Mop, Prop, Suction};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// A change to the robot's saved rooms. Positions are in millimeters.
pub enum RoomEdit {
    Merge(u32, u32),
    Divide { room: u32, from: (f64, f64), to: (f64, f64) },
}

/// A failure with a message that is safe to show to a person or an agent.
#[derive(Debug)]
pub struct ToolError(pub String);

impl ToolError {
    pub fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}
impl From<MiioError> for ToolError {
    fn from(e: MiioError) -> Self {
        Self(e.to_string())
    }
}
impl From<crate::cloud::CloudError> for ToolError {
    fn from(e: crate::cloud::CloudError) -> Self {
        Self(e.to_string())
    }
}

#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Fault {
    pub code: i64,
    pub description: String,
}

#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Consumables {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub main_brush_percent_left: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub side_brush_percent_left: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub filter_percent_left: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mop_pad_percent_left: Option<i64>,
}

#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Totals {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cleans: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub minutes: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "areaM2")]
    pub area_m2: Option<i64>,
}

/// Everything an agent needs to know about the robot, as plain JSON.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RobotStatus {
    pub online: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state_code: Option<i64>,
    pub busy: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub battery_percent: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fault: Option<Fault>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub suction: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mop_level: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cleaning_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "currentCleanMinutes")]
    pub current_clean_minutes: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "currentCleanAreaM2")]
    pub current_clean_area_m2: Option<i64>,
    pub consumables: Consumables,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub do_not_disturb: Option<String>,
    pub totals: Totals,
    /// Seconds since the robot last answered.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub age_seconds: Option<u64>,
    /// Said when the values are old because the robot has stopped answering.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RoomInfo {
    pub id: u32,
    pub name: String,
    #[serde(rename = "areaM2")]
    pub area_m2: f64,
    /// Where the room is, in meters in the map's coordinates: [min x, min y, max x, max y] (x right, y up).
    #[serde(rename = "boundsM", skip_serializing_if = "Option::is_none")]
    pub bounds_m: Option<[f64; 4]>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub suction: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mop_level: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cleaning_mode: Option<String>,
    pub repeats: i64,
}

#[derive(Default)]
struct State {
    values: HashMap<Prop, Value>,
    /// When the robot last answered.
    updated_at: Option<Instant>,
    /// When the last attempt to read it ended (whether or not it answered).
    last_attempt: Option<Instant>,
    /// How many readings in a row failed.
    failures: u32,
    connection_error: Option<String>,
    map: Option<(Arc<VacuumMap>, Instant)>,
}

pub struct RobotService {
    config: RobotConfig,
    cloud: Option<CloudSession>,
    client: MiioClient,
    /// Its own socket, so drive commands never wait behind status polls.
    drive_client: MiioClient,
    state: Mutex<State>,
    driving: AtomicBool,
    /// When the app last sent a drive command through the raw channel; polling pauses meanwhile.
    last_raw_drive: Mutex<Option<Instant>>,
    map_lock: tokio::sync::Mutex<()>,
    /// Only one reading of the robot runs at a time; callers that arrive meanwhile share its result.
    refresh_lock: tokio::sync::Mutex<()>,
    timings: Timings,
}

/// How long things may take before an answer is given anyway. Short in tests.
#[derive(Clone, Copy)]
pub struct Timings {
    /// One request while reading the robot's state.
    pub poll_timeout: Duration,
    /// The first status call, before any reading has happened.
    pub first_reading_wait: Duration,
    /// A status call that asks for a fresh reading.
    pub fresh_wait: Duration,
}

impl Default for Timings {
    fn default() -> Self {
        Self { poll_timeout: Duration::from_secs(3), first_reading_wait: Duration::from_secs(6), fresh_wait: Duration::from_secs(8) }
    }
}

/// Seconds to wait before the next reading: quick while things work, gentler while the robot is silent.
pub fn poll_delay(failures: u32) -> Duration {
    Duration::from_secs(match failures {
        0 | 1 => 5,
        2 => 10,
        _ => 15,
    })
}

const MAP_RETRY_DELAYS: [Duration; 3] = [Duration::from_secs(1), Duration::from_secs(2), Duration::from_secs(4)];

/// Why fetching the map failed, and whether trying again could help.
pub enum MapFailure {
    Retry(ToolError),
    Fatal(ToolError),
}

impl MapFailure {
    fn into_error(self) -> ToolError {
        match self {
            Self::Retry(e) | Self::Fatal(e) => e,
        }
    }
}

/// Runs `operation`, and after each retryable failure waits and tries again (`delays.len()` more times at most).
pub async fn retrying<T, Fut>(delays: &[Duration], mut operation: impl FnMut() -> Fut) -> Result<T, MapFailure>
where
    Fut: std::future::Future<Output = Result<T, MapFailure>>,
{
    let mut attempt = 0;
    loop {
        match operation().await {
            Err(MapFailure::Retry(_)) if attempt < delays.len() => {
                tokio::time::sleep(delays[attempt]).await;
                attempt += 1;
            }
            other => return other,
        }
    }
}

/// Millimeters -> meters, to one decimal, for what agents read and write.
fn meters(b: crate::map::Bounds) -> [f64; 4] {
    b.map(|mm| (mm / 100.0).round() / 10.0)
}

pub const MAX_DRIVE_VELOCITY: i64 = 600;
pub const MAX_DRIVE_ROTATION: i64 = 128;
pub const MAX_DRIVE_MILLISECONDS: i64 = 10_000;

impl RobotService {
    pub fn new(config: RobotConfig, cloud: Option<CloudSession>) -> Result<Arc<Self>, ToolError> {
        Self::new_with(config, cloud, Timings::default())
    }

    pub fn new_with(config: RobotConfig, cloud: Option<CloudSession>, timings: Timings) -> Result<Arc<Self>, ToolError> {
        let token: [u8; 16] = hex::decode(&config.token)
            .ok()
            .and_then(|b| b.try_into().ok())
            .ok_or_else(|| ToolError::new("The robot token must be 32 hex characters."))?;
        Ok(Arc::new(Self {
            client: MiioClient::new(config.ip.clone(), token),
            drive_client: MiioClient::new(config.ip.clone(), token),
            config,
            cloud,
            state: Mutex::new(State::default()),
            driving: AtomicBool::new(false),
            last_raw_drive: Mutex::new(None),
            map_lock: tokio::sync::Mutex::new(()),
            refresh_lock: tokio::sync::Mutex::new(()),
            timings,
        }))
    }

    #[cfg(test)]
    pub fn inject_map(&self, map: VacuumMap) {
        self.state.lock().unwrap().map = Some((Arc::new(map), Instant::now()));
    }

    // MARK: - Polling

    /// Polls until this service is dropped (e.g. replaced after the settings changed).
    pub fn start_polling(self: &Arc<Self>) {
        let weak = Arc::downgrade(self);
        tokio::spawn(async move {
            loop {
                let Some(service) = weak.upgrade() else { return };
                service.refresh().await;
                let delay = poll_delay(service.state.lock().unwrap().failures);
                drop(service);
                tokio::time::sleep(delay).await;
            }
        });
    }

    fn is_driving(&self) -> bool {
        self.driving.load(Ordering::SeqCst) || self.last_raw_drive.lock().unwrap().map_or(false, |t| t.elapsed() < Duration::from_secs(2))
    }

    /// The raw property values (keys like "2.1") for the Mac app, which interprets them itself.
    /// Answers from the last reading; only the very first call waits (a little) for the robot.
    pub async fn properties(&self) -> Value {
        self.ensure_first_attempt().await;
        let state = self.state.lock().unwrap();
        let values: serde_json::Map<String, Value> = state.values.iter().map(|((siid, piid), v)| (format!("{siid}.{piid}"), v.clone())).collect();
        json!({
            "online": state.connection_error.is_none() && state.updated_at.is_some(),
            "error": state.connection_error,
            "ageSeconds": state.updated_at.map(|t| t.elapsed().as_secs()),
            "values": values,
        })
    }

    /// Sends a raw miIO request on behalf of the Mac app. The `drive` channel has its own socket
    /// so steering never waits behind other traffic.
    pub async fn raw(&self, method: &str, params: Value, timeout: Duration, retry: bool, drive_channel: bool) -> Result<Value, MiioError> {
        // A room edit (from the Mac app or an agent) changes the rooms: forget the map we have.
        if method == "action" && params["siid"] == 6 && params["aiid"] == 2 {
            self.state.lock().unwrap().map = None;
        }
        if drive_channel {
            *self.last_raw_drive.lock().unwrap() = Some(Instant::now());
            self.drive_client.send(method, params, timeout, retry).await
        } else {
            self.client.send(method, params, timeout, retry).await
        }
    }

    /// Reads the robot now. If a reading is already running, waits for it instead of starting another,
    /// so many callers never pile up behind a silent robot.
    pub async fn refresh(&self) {
        if self.is_driving() {
            return;
        }
        let started = Instant::now();
        let _single_flight = self.refresh_lock.lock().await;
        if self.state.lock().unwrap().last_attempt.map_or(false, |t| t > started) {
            return; // the reading we waited for has just finished
        }
        let outcome = self.read_properties().await;
        let mut state = self.state.lock().unwrap();
        state.last_attempt = Some(Instant::now());
        match outcome {
            Ok(values) => {
                state.values = values;
                state.updated_at = Some(Instant::now());
                state.connection_error = None;
                state.failures = 0;
            }
            Err(e) => {
                state.connection_error = Some(e.to_string());
                state.failures += 1;
            }
        }
    }

    /// `refresh`, but gives up waiting after `wait` and says why. The robot may still be slow; the
    /// background reading carries on and the next call sees its result.
    async fn refresh_within(&self, wait: Duration) {
        if tokio::time::timeout(wait, self.refresh()).await.is_err() {
            let mut state = self.state.lock().unwrap();
            state.last_attempt = Some(Instant::now());
            state.connection_error.get_or_insert_with(|| MiioError::Timeout.to_string());
        }
    }

    /// Before anything has been read, wait (a little) for the first attempt so the first answer isn't empty.
    async fn ensure_first_attempt(&self) {
        if self.state.lock().unwrap().last_attempt.is_none() {
            self.refresh_within(self.timings.first_reading_wait).await;
        }
    }

    async fn read_properties(&self) -> Result<HashMap<Prop, Value>, MiioError> {
        let mut updated = HashMap::new();
        for batch in spec::POLLED.chunks(10) {
            let request: Vec<Value> = batch.iter().map(|(siid, piid)| json!({"did": format!("{siid}.{piid}"), "siid": siid, "piid": piid})).collect();
            // A silent robot is detected by the first request; there's no point asking the rest.
            let result = self.client.send_quick("get_properties", Value::Array(request), self.timings.poll_timeout).await?;
            for item in result.as_array().into_iter().flatten() {
                if item["code"].as_i64() != Some(0) {
                    continue;
                }
                if let (Some(siid), Some(piid), Some(value)) = (item["siid"].as_u64(), item["piid"].as_u64(), item.get("value")) {
                    updated.insert((siid as u32, piid as u32), value.clone());
                }
            }
        }
        Ok(updated)
    }

    /// The robot's state, from the last reading (the background reader keeps it a few seconds old at most).
    /// It never waits long for a silent robot: with `fresh` it asks again but gives up after a few seconds,
    /// and says so (`online: false`, the reason, and how old the values are).
    pub async fn status(&self, fresh: bool) -> RobotStatus {
        if fresh {
            self.refresh_within(self.timings.fresh_wait).await;
        } else {
            self.ensure_first_attempt().await;
        }
        self.snapshot()
    }

    fn int(&self, prop: Prop) -> Option<i64> {
        self.state.lock().unwrap().values.get(&prop).and_then(|v| v.as_i64())
    }

    fn snapshot(&self) -> RobotStatus {
        let state = self.state.lock().unwrap();
        let int = |p: Prop| state.values.get(&p).and_then(|v| v.as_i64());
        let code = int(spec::STATUS);
        let dnd = state.values.get(&spec::DND_ENABLED).and_then(|v| v.as_bool()).map(|enabled| {
            if !enabled {
                return "off".to_string();
            }
            let show = |p: Prop| state.values.get(&p).map(|v| v.as_str().map(String::from).unwrap_or_else(|| v.to_string())).unwrap_or("?".into());
            format!("{} - {}", show(spec::DND_START), show(spec::DND_END))
        });
        RobotStatus {
            online: state.connection_error.is_none() && state.updated_at.is_some(),
            error: state.connection_error.clone(),
            state: code.map(spec::status_name),
            state_code: code,
            busy: code.map_or(false, spec::is_busy),
            battery_percent: int(spec::BATTERY),
            fault: int(spec::FAULT).filter(|c| *c != 0).map(|c| Fault { code: c, description: spec::error_name(c) }),
            suction: int(spec::SUCTION).and_then(Suction::from_raw).map(|s| s.name().to_string()),
            mop_level: int(spec::MOP_LEVEL).and_then(Mop::from_raw).map(|s| s.name().to_string()),
            cleaning_mode: int(spec::CLEAN_SETTING).and_then(Mode::from_packed).map(|s| s.name().to_string()),
            current_clean_minutes: int(spec::CLEANING_TIME),
            current_clean_area_m2: int(spec::CLEANING_AREA),
            consumables: Consumables {
                main_brush_percent_left: int(spec::MAIN_BRUSH),
                side_brush_percent_left: int(spec::SIDE_BRUSH),
                filter_percent_left: int(spec::FILTER),
                mop_pad_percent_left: int(spec::MOP_PAD),
            },
            do_not_disturb: dnd,
            totals: Totals { cleans: int(spec::TOTAL_CLEANS), minutes: int(spec::TOTAL_CLEANING_MINUTES), area_m2: int(spec::TOTAL_AREA) },
            age_seconds: state.updated_at.map(|t| t.elapsed().as_secs()),
            note: match (state.connection_error.is_some(), state.updated_at) {
                (true, Some(at)) => Some(format!("The robot isn't answering right now. These values are the last ones it reported, {} seconds ago.", at.elapsed().as_secs())),
                _ => None,
            },
        }
    }

    // MARK: - Commands

    pub async fn run(&self, action: Action, params: Vec<Value>) -> Result<(), ToolError> {
        let (siid, aiid) = action;
        let result = self
            .client
            .send_default("action", json!({"did": format!("{siid}.{aiid}"), "siid": siid, "aiid": aiid, "in": params}))
            .await?;
        if let Some(code) = result["code"].as_i64().filter(|c| *c != 0) {
            return Err(ToolError::new(format!("The robot rejected the command (code {code}).")));
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
        self.refresh().await;
        Ok(())
    }

    async fn set(&self, property: Prop, value: Value) -> Result<(), ToolError> {
        let (siid, piid) = property;
        let result = self
            .client
            .send_default("set_properties", json!([{"did": format!("{siid}.{piid}"), "siid": siid, "piid": piid, "value": value}]))
            .await?;
        if let Some(code) = result[0]["code"].as_i64().filter(|c| *c != 0) {
            return Err(ToolError::new(format!("The robot rejected the setting (code {code}).")));
        }
        self.state.lock().unwrap().values.insert(property, value);
        Ok(())
    }

    pub async fn set_suction(&self, level: Suction) -> Result<(), ToolError> {
        self.set(spec::SUCTION, json!(level as i64)).await
    }
    pub async fn set_mop(&self, level: Mop) -> Result<(), ToolError> {
        self.set(spec::MOP_LEVEL, json!(level as i64)).await
    }

    pub async fn set_cleaning_mode(&self, mode: Mode) -> Result<(), ToolError> {
        if self.int(spec::CLEAN_SETTING).is_none() {
            self.refresh().await;
        }
        let current = self.int(spec::CLEAN_SETTING).ok_or_else(|| ToolError::new("The robot didn't report its cleaning settings."))?;
        self.set(spec::CLEAN_SETTING, json!(mode.packed_into(current))).await?;
        self.refresh().await; // the robot may refuse (e.g. mop pads not attached); report what it really uses
        if self.int(spec::CLEAN_SETTING).and_then(Mode::from_packed) != Some(mode) {
            return Err(ToolError::new(format!("The robot didn't switch to {} (are the mop pads attached?).", mode.name().to_lowercase())));
        }
        Ok(())
    }

    // MARK: - Rooms

    pub async fn rooms(&self) -> Result<Vec<RoomInfo>, ToolError> {
        let map = self.current_map().await?;
        let hidden = config::hidden_rooms();
        let names = config::room_names();
        let preferences = config::room_preferences();
        Ok(map
            .room_ids()
            .into_iter()
            .filter(|id| !hidden.contains(id))
            .map(|id| {
                let preference = preferences.get(&id).cloned().unwrap_or_default();
                RoomInfo {
                    id,
                    name: names.get(&id).cloned().unwrap_or_else(|| format!("Room {id}")),
                    area_m2: (map.area_of_room(id) * 10.0).round() / 10.0,
                    bounds_m: map.room_bounds(id).map(meters),
                    suction: preference.suction.and_then(Suction::from_raw).map(|s| s.name().to_string()),
                    mop_level: preference.water.and_then(Mop::from_raw).map(|s| s.name().to_string()),
                    cleaning_mode: preference.mode.and_then(Mode::from_raw).map(|s| s.name().to_string()),
                    repeats: if preference.repeats == 0 { 1 } else { preference.repeats },
                }
            })
            .collect())
    }

    /// Cleans these rooms (by id or by name). Per-room settings saved in the Mac app apply unless overridden here.
    pub async fn clean_rooms(&self, refs: &[String], suction: Option<Suction>, mop: Option<Mop>, mode: Option<Mode>, repeats: Option<i64>) -> Result<(), ToolError> {
        let available = self.rooms().await?;
        let mut ids: Vec<u32> = vec![];
        for reference in refs {
            let trimmed = reference.trim();
            let by_id = trimmed.parse::<u32>().ok().filter(|id| available.iter().any(|r| r.id == *id));
            let found = by_id.or_else(|| available.iter().find(|r| r.name.to_lowercase() == trimmed.to_lowercase()).map(|r| r.id));
            match found {
                Some(id) => ids.push(id),
                None => {
                    let known: Vec<String> = available.iter().map(|r| format!("{} ({})", r.name, r.id)).collect();
                    return Err(ToolError::new(format!("Unknown room '{reference}'. Known rooms: {}.", known.join(", "))));
                }
            }
        }
        ids.sort_unstable();
        ids.dedup();
        if ids.is_empty() {
            return Err(ToolError::new("No rooms given."));
        }

        if self.state.lock().unwrap().values.is_empty() {
            self.refresh().await;
        }
        let preferences = config::room_preferences();
        let current_mode = self.int(spec::CLEAN_SETTING).and_then(Mode::from_packed);
        // The robot has one cleaning mode per job, so rooms asking for different modes can't run together.
        let mut modes: Vec<i64> = ids
            .iter()
            .map(|id| mode.or_else(|| preferences.get(id).and_then(|p| p.mode).and_then(Mode::from_raw)).or(current_mode).unwrap_or(Mode::Vacuum) as i64)
            .collect();
        modes.sort_unstable();
        modes.dedup();
        if modes.len() != 1 {
            return Err(ToolError::new("The selected rooms use different cleaning modes. Clean them separately or pass a mode."));
        }
        let wanted = Mode::from_raw(modes[0]).unwrap();
        if Some(wanted) != current_mode {
            self.set_cleaning_mode(wanted).await?;
        }

        let default_suction = suction.map(|s| s as i64).or(self.int(spec::SUCTION)).unwrap_or(1);
        let default_water = mop.map(|m| m as i64).or(self.int(spec::MOP_LEVEL)).unwrap_or(2);
        let selects: Vec<Value> = ids
            .iter()
            .map(|id| {
                let preference = preferences.get(id).cloned().unwrap_or_default();
                let preferred_repeats = if preference.repeats == 0 { 1 } else { preference.repeats };
                json!([
                    id,
                    repeats.unwrap_or(preferred_repeats).clamp(1, spec::MAX_REPEATS),
                    suction.map(|s| s as i64).or(preference.suction).unwrap_or(default_suction),
                    mop.map(|m| m as i64).or(preference.water).unwrap_or(default_water),
                    1
                ])
            })
            .collect();
        let data = json!({"selects": selects}).to_string();
        self.run(
            spec::START_CUSTOM_CLEAN,
            vec![
                json!({"piid": 1, "value": spec::SEGMENT_CLEANING_WORK_MODE}),
                json!({"piid": spec::CLEAN_EXTEND_DATA_PIID, "value": data}),
            ],
        )
        .await
    }

    async fn current_map(&self) -> Result<Arc<VacuumMap>, ToolError> {
        Ok(self.current_map_within(Duration::from_secs(600)).await?.0)
    }

    /// The map, downloaded again if the one we have is older than `max_age`. If downloading fails, an older map
    /// is better than none; the returned time says when it was actually read.
    async fn current_map_within(&self, max_age: Duration) -> Result<(Arc<VacuumMap>, Instant), ToolError> {
        let cached = self.state.lock().unwrap().map.clone();
        if let Some((map, at)) = &cached {
            if at.elapsed() < max_age {
                return Ok((map.clone(), *at));
            }
        }
        let _guard = self.map_lock.lock().await; // one download at a time
        if let Some((map, at)) = self.state.lock().unwrap().map.clone() {
            if at.elapsed() < max_age {
                return Ok((map, at));
            }
        }
        match self.fetch_map().await {
            Ok(map) => {
                let (map, at) = (Arc::new(map), Instant::now());
                self.state.lock().unwrap().map = Some((map.clone(), at));
                Ok((map, at))
            }
            Err(e) => cached.ok_or(e),
        }
    }

    /// Draws the map as a PNG in the pictures folder and says where it is. Hidden rooms stay hidden, like in the app.
    pub async fn map_image(&self, fresh: bool, grid: bool) -> Result<Value, ToolError> {
        let max_age = if fresh { Duration::ZERO } else { Duration::from_secs(600) };
        let (map, read_at) = self.current_map_within(max_age).await?;
        self.draw_map(&map, read_at, crate::render::Options { grid, ..Default::default() }, true)
    }

    fn draw_map(&self, map: &VacuumMap, read_at: Instant, options: crate::render::Options, respect_hidden: bool) -> Result<Value, ToolError> {
        let (hidden, names) = (if respect_hidden { config::hidden_rooms() } else { Default::default() }, config::room_names());
        let visible = map.hiding(&hidden);
        let labels: Vec<crate::render::RoomLabel> = visible
            .room_ids()
            .into_iter()
            .filter(|id| !hidden.contains(id))
            .map(|id| crate::render::RoomLabel { id, name: names.get(&id).cloned().unwrap_or_else(|| format!("Room {id}")), area_m2: (visible.area_of_room(id) * 10.0).round() / 10.0 })
            .collect();
        let legend = labels
            .iter()
            .map(|l| json!({"id": l.id, "name": l.name, "areaM2": l.area_m2, "boundsM": visible.room_bounds(l.id).map(meters)}))
            .collect::<Vec<_>>();
        let rendered = crate::render::render_with(&visible, &labels, &options).map_err(ToolError::new)?;

        let MapFolder { path: folder, private } = config::map_images_dir();
        // Only vacuumd's own folder is locked down; a folder the user chose keeps its permissions.
        let made = if private { config::ensure_private_dir(&folder) } else { std::fs::create_dir_all(&folder) };
        made.map_err(|e| ToolError::new(format!("Couldn't create {}: {e}", folder.display())))?;
        // Unique even for two pictures in the same second (a preview and the picture right after it).
        let stamp = chrono::Local::now().format("%Y%m%d-%H%M%S-%3f").to_string();
        let mut path = folder.join(format!("vacuum-map-{stamp}.png"));
        for extra in 1.. {
            if !path.exists() {
                break;
            }
            path = folder.join(format!("vacuum-map-{stamp}-{extra}.png"));
        }
        let saved = if private { config::write_private(&path, &rendered.png) } else { std::fs::write(&path, &rendered.png) };
        saved.map_err(|e| ToolError::new(format!("Couldn't save {}: {e}", path.display())))?;
        config::keep_newest_map_images(&folder, 10);
        // How the picture was drawn, so a window can place things (furniture) on it: a robot position in mm maps to
        // x = offsetX + (mm - left) / gridSizeMm * scale, y = (mapHeight - (mm - top) / gridSizeMm) * scale, in pixels.
        let (w, h) = (visible.header.width, visible.header.height);
        let scale = (1600 / w.max(h).max(1)).clamp(2, 8);
        let offset_x = (rendered.width as i64 - (w as i64) * scale as i64) / 2;
        Ok(json!({
            "path": path.to_string_lossy(),
            "width": rendered.width,
            "height": rendered.height,
            "mapAgeSeconds": read_at.elapsed().as_secs(),
            "legend": legend,
            "mapTransform": {"leftMm": visible.header.left, "topMm": visible.header.top, "gridSizeMm": visible.header.grid_size, "scale": scale, "offsetX": offset_x, "mapWidth": w, "mapHeight": h},
            "message": "Saved the map as a PNG. Give the user this file path (or attach the file) to show it.",
        }))
    }

    // MARK: - Room editing (merge / divide on the robot's saved map)

    /// Merge two neighboring rooms, or divide one with a straight line (coordinates in meters, like `boundsM`).
    /// Without `confirm` nothing is sent: a picture shows what would happen. These edits change the robot's saved map.
    pub async fn edit_rooms(&self, request: RoomEdit, confirm: bool) -> Result<Value, ToolError> {
        let (map, read_at) = self.current_map_within(Duration::from_secs(60)).await?;
        let known = map.room_ids();
        let must_exist = |id: u32| if known.contains(&id) { Ok(()) } else { Err(ToolError::new(format!("There is no room {id}. Rooms on the map: {known:?}."))) };

        let (payload, summary, preview) = match request {
            RoomEdit::Merge(a, b) => {
                if a == b {
                    return Err(ToolError::new("Choose two different rooms to merge."));
                }
                must_exist(a)?;
                must_exist(b)?;
                // If the robot didn't report neighbors, let it decide.
                if !map.neighbors.is_empty() && !map.neighbors.get(&a).map_or(false, |n| n.contains(&b)) {
                    return Err(ToolError::new(format!("Rooms {a} and {b} don't touch, so they can't be merged. Room {a} touches: {:?}.", map.neighbors.get(&a).map(|n| { let mut v: Vec<_> = n.iter().collect(); v.sort(); v }).unwrap_or_default())));
                }
                let (lo, hi) = (a.min(b), a.max(b));
                (
                    json!({"msr": [lo, hi], "mapid": map.saved_map_id.unwrap_or(0)}),
                    format!("Merge room {lo} and room {hi} into one room."),
                    crate::render::Options { grid: true, line: None, highlight: vec![lo, hi] },
                )
            }
            RoomEdit::Divide { room, from, to } => {
                must_exist(room)?;
                if ((to.0 - from.0).powi(2) + (to.1 - from.1).powi(2)).sqrt() < 300.0 {
                    return Err(ToolError::new("The dividing line must be at least 0.3 m long."));
                }
                // The robot expects the line to cross the whole room, so extend it past the room's edges.
                let bounds = map.room_bounds(room).ok_or_else(|| ToolError::new("That room has no cells on the map."))?;
                let (a, b) = crate::map::extend_line(from, to, bounds, 300.0);
                let values: Vec<i64> = [a.0, a.1, b.0, b.1].iter().map(|v| v.round() as i64).chain([room as i64]).collect();
                (
                    json!({"dsrid": values, "mapid": map.saved_map_id.unwrap_or(0)}),
                    format!("Divide room {room} along the line drawn."),
                    crate::render::Options { grid: true, line: Some((a, b)), highlight: vec![room] },
                )
            }
        };

        if !confirm {
            let picture = self.draw_map(&map, read_at, preview, false)?;
            return Ok(json!({
                "preview": true,
                "nothingWasChanged": true,
                "wouldDo": summary,
                "picture": picture["path"],
                "next": "Show the user this picture and ask whether to go ahead. Only if they agree, call this tool again with the same arguments and confirm: true.",
                "warning": "This changes the robot's saved map. It can only be undone by merging or dividing rooms again.",
            }));
        }

        let before: Vec<Value> = known.iter().map(|id| json!({"id": id, "areaM2": (map.area_of_room(*id) * 10.0).round() / 10.0})).collect();
        let value = payload.to_string();
        let reply = self
            .client
            .send_default("action", json!({"did": "6.2", "siid": 6, "aiid": 2, "in": [{"piid": 4, "value": value}]}))
            .await?;
        let result_code = reply["out"].as_array().and_then(|out| out.iter().find(|o| o["piid"] == 6)).and_then(|o| o["value"].as_i64()).unwrap_or(0);
        if reply["code"].as_i64().unwrap_or(0) != 0 || result_code != 0 {
            return Err(ToolError::new(format!("The robot didn't accept the change (code {}). Nothing was changed.", if result_code != 0 { result_code } else { reply["code"].as_i64().unwrap_or(-1) })));
        }
        self.state.lock().unwrap().map = None; // the rooms are being recomputed
        let settle = std::env::var("VACUUMD_EDIT_SETTLE_MS").ok().and_then(|v| v.parse().ok()).unwrap_or(4000);
        tokio::time::sleep(Duration::from_millis(settle)).await; // the robot recomputes its rooms
        let after = self.rooms_unfiltered().await.ok();
        config::log_room_edit(&json!({"date": chrono::Local::now().to_rfc3339(), "request": payload, "roomsBefore": before, "roomsAfter": after}));
        let mut warnings = vec![
            "Room numbers may have changed. Use the list above, not the old numbers.".to_string(),
            "Hidden rooms, room names and per-room settings in the Vacuum app are stored by room number: check that they still match.".to_string(),
        ];
        if after.is_none() {
            warnings.push("The new room list isn't available yet; call list_rooms in a few seconds.".to_string());
        }
        Ok(json!({"ok": true, "did": summary, "rooms": after, "warnings": warnings}))
    }

    /// Every room on the map, hidden ones included (what the robot has), after a fresh download.
    async fn rooms_unfiltered(&self) -> Result<Vec<RoomInfo>, ToolError> {
        let (map, _) = self.current_map_within(Duration::ZERO).await?;
        let names = config::room_names();
        Ok(map
            .room_ids()
            .into_iter()
            .map(|id| RoomInfo {
                id,
                name: names.get(&id).cloned().unwrap_or_else(|| format!("Room {id}")),
                area_m2: (map.area_of_room(id) * 10.0).round() / 10.0,
                bounds_m: map.room_bounds(id).map(meters),
                suction: None,
                mop_level: None,
                cleaning_mode: None,
                repeats: 1,
            })
            .collect())
    }

    /// Same route as the Mac app: ask the robot for a full map; if it won't answer, take its latest upload from the cloud.
    /// A docked robot is often asleep, or answers before the file has reached the cloud, and the cloud's latest file
    /// sometimes can't be read: so a failed attempt is simply tried again a few times.
    async fn fetch_map(&self) -> Result<VacuumMap, ToolError> {
        retrying(&MAP_RETRY_DELAYS, || self.fetch_map_once()).await.map_err(|e| e.into_error())
    }

    async fn fetch_map_once(&self) -> Result<VacuumMap, MapFailure> {
        use crate::cloud::CloudError;
        let cloud = self.cloud.clone().ok_or_else(|| MapFailure::Fatal(ToolError::new("Run `vacuumd setup` first; room names need the robot's map and a Xiaomi sign-in.")))?;
        let retryable = |e: CloudError| match e {
            CloudError::LoginExpired => MapFailure::Fatal(e.into()),
            other => MapFailure::Retry(other.into()),
        };
        let xiaomi = XiaomiCloud::new(cloud);
        let (siid, aiid) = spec::REQUEST_MAP;
        let request = r#"{"req_type":1,"frame_type":"I","force_type":1}"#;
        let reply = self
            .client
            .send_default("action", json!({"did": format!("{siid}.{aiid}"), "siid": siid, "aiid": aiid, "in": [{"piid": spec::MAP_FRAME_INFO_PIID, "value": request}]}))
            .await;
        let from_robot_ok = reply.is_ok();
        let mut object_name = reply
            .ok()
            .and_then(|r| r["out"].as_array().cloned())
            .and_then(|out| out.iter().find(|o| o["piid"].as_u64() == Some(spec::MAP_OBJECT_NAME_PIID as u64)).cloned())
            .and_then(|o| o["value"].as_str().map(String::from))
            .unwrap_or_default();
        let mut source = "robot";
        if object_name.is_empty() {
            source = if from_robot_ok { "cloud(robot sent no name)" } else { "cloud(robot unreachable)" };
            object_name = xiaomi.last_map_object_name(&self.config.did).await.map_err(retryable)?.unwrap_or_default();
        }
        if object_name.is_empty() {
            return Err(MapFailure::Retry(ToolError::new("The robot didn't send a map.")));
        }
        let (name, key) = match object_name.split_once(',') {
            Some((name, key)) => (name.to_string(), Some(key.to_string())),
            None => (object_name.clone(), None),
        };
        let raw = xiaomi.download(&xiaomi.map_file_url(&name).await.map_err(retryable)?).await.map_err(retryable)?;
        let (raw_len, has_key) = (raw.len(), key.is_some());
        let decoded = tokio::task::spawn_blocking(move || map::decode(&raw, key.as_deref()))
            .await
            .map_err(|e| MapFailure::Retry(ToolError::new(e.to_string())))?;
        decoded.map_err(|e| {
            println!("map decode failed: {e} [source={source}, downloaded={raw_len} chars, key={has_key}]"); // no names or keys
            MapFailure::Retry(ToolError::new(format!("The robot's map couldn't be read ({e}). Try again in a moment.")))
        })
    }

    // MARK: - Driving

    /// Drives for `milliseconds` (commands every 150 ms, like the app's pad), then stops and leaves manual mode.
    pub async fn drive(&self, velocity: i64, rotation: i64, milliseconds: i64) -> Result<(), ToolError> {
        if self.driving.swap(true, Ordering::SeqCst) {
            return Err(ToolError::new("The robot is already being driven."));
        }
        struct Release<'a>(&'a AtomicBool);
        impl Drop for Release<'_> {
            fn drop(&mut self) {
                self.0.store(false, Ordering::SeqCst);
            }
        }
        let _release = Release(&self.driving);
        let velocity = velocity.clamp(-MAX_DRIVE_VELOCITY, MAX_DRIVE_VELOCITY);
        let rotation = rotation.clamp(-MAX_DRIVE_ROTATION, MAX_DRIVE_ROTATION);
        let milliseconds = milliseconds.clamp(100, MAX_DRIVE_MILLISECONDS);

        let end = Instant::now() + Duration::from_millis(milliseconds as u64);
        let (mut announced, mut failures) = (false, 0);
        let outcome: Result<(), ToolError> = async {
            while Instant::now() < end {
                if self.send_drive(velocity, rotation, announced).await? {
                    announced = true;
                    failures = 0;
                } else {
                    failures += 1;
                }
                if failures >= 15 {
                    return Err(ToolError::new("The robot stopped answering drive commands."));
                }
                tokio::time::sleep(Duration::from_millis(150)).await;
            }
            Ok(())
        }
        .await;
        let _ = self.send_drive(0, 0, true).await;
        if outcome.is_ok() && announced {
            let _ = self.run(spec::STOP_CLEANING, vec![]).await; // leave manual mode
        }
        outcome
    }

    /// True when the robot acknowledged; false for a lost reply (normal while driving).
    async fn send_drive(&self, velocity: i64, rotation: i64, quiet: bool) -> Result<bool, ToolError> {
        let (siid, piid) = spec::REMOTE_CONTROL;
        let payload = format!(r#"{{"spdv":{velocity},"spdw":{rotation},"audio":"{}","random":{}}}"#, !quiet, rand::random::<u16>());
        let result = self
            .drive_client
            .send(
                "set_properties",
                json!([{"did": format!("{siid}.{piid}"), "siid": siid, "piid": piid, "value": payload}]),
                Duration::from_millis(300),
                false,
            )
            .await;
        match result {
            Ok(reply) => match reply[0]["code"].as_i64().filter(|c| *c != 0) {
                Some(code) => Err(ToolError::new(format!("The robot rejected the drive command (code {code}). It may need to be off its dock."))),
                None => Ok(true),
            },
            Err(MiioError::Timeout) => Ok(false),
            Err(e) => Err(e.into()),
        }
    }
}
