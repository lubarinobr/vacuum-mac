//! MIoT spec for xiaomi.vacuum.c102gl (Xiaomi Robot Vacuum X20+), from miot-spec.org.
//! Each property/action is addressed by (siid, piid) or (siid, aiid).
use serde::{Deserialize, Serialize};

pub type Prop = (u32, u32);
pub type Action = (u32, u32);

pub const STATUS: Prop = (2, 1);
pub const FAULT: Prop = (2, 2);
pub const SUCTION: Prop = (2, 3);
pub const BATTERY: Prop = (3, 1);
pub const CHARGING_STATE: Prop = (3, 2);
pub const WORK_MODE: Prop = (4, 1);
pub const CLEANING_TIME: Prop = (4, 2);
pub const CLEANING_AREA: Prop = (4, 3);
pub const MOP_LEVEL: Prop = (4, 5);
/// Packed value: bits 0-1 = cleaning mode, higher bytes = mop-washing settings.
pub const CLEAN_SETTING: Prop = (4, 23);
pub const MAIN_BRUSH: Prop = (9, 2);
pub const SIDE_BRUSH: Prop = (10, 2);
pub const FILTER: Prop = (11, 1);
pub const MOP_PAD: Prop = (18, 1);
pub const DND_ENABLED: Prop = (5, 1);
pub const DND_START: Prop = (5, 2);
pub const DND_END: Prop = (5, 3);
pub const SCHEDULES: Prop = (8, 2);
/// Manual driving: a JSON string {"spdv": velocity, "spdw": rotation, "audio": "true|false", "random": n}.
pub const REMOTE_CONTROL: Prop = (4, 15);
pub const TOTAL_CLEANING_MINUTES: Prop = (12, 2);
pub const TOTAL_CLEANS: Prop = (12, 3);
pub const TOTAL_AREA: Prop = (12, 4);

pub const POLLED: [Prop; 21] = [
    STATUS, FAULT, SUCTION, BATTERY, CHARGING_STATE, WORK_MODE, CLEANING_TIME, CLEANING_AREA, MOP_LEVEL, CLEAN_SETTING,
    MAIN_BRUSH, SIDE_BRUSH, FILTER, MOP_PAD, DND_ENABLED, DND_START, DND_END, SCHEDULES,
    TOTAL_CLEANING_MINUTES, TOTAL_CLEANS, TOTAL_AREA,
];

pub const START_CLEANING: Action = (2, 1);
pub const STOP_CLEANING: Action = (2, 2);
pub const EMPTY_BIN: Action = (2, 4);
pub const GO_HOME: Action = (3, 1);
pub const LOCATE: Action = (7, 1);
pub const REQUEST_MAP: Action = (6, 1);
pub const MAP_FRAME_INFO_PIID: u32 = 2;
pub const MAP_OBJECT_NAME_PIID: u32 = 3;

/// Room cleaning: start-clean with work-mode 18 and the room list.
pub const START_CUSTOM_CLEAN: Action = (4, 1);
pub const SEGMENT_CLEANING_WORK_MODE: i64 = 18;
pub const CLEAN_EXTEND_DATA_PIID: u32 = 10;

pub fn status_name(code: i64) -> String {
    match code {
        1 => "Sweeping", 2 => "Idle", 3 => "Paused", 4 => "Error", 5 => "Going home", 6 => "Charging", 7 => "Mopping",
        8 => "Drying mop", 9 => "Washing mop", 10 => "Going to wash", 11 => "Building map", 12 => "Sweeping and mopping",
        13 => "Fully charged", 14 => "Updating", 19 => "Checking water", 21 => "Mop wash paused", 22 => "Emptying bin",
        23 => "Remote control",
        _ => return format!("Status {code}"),
    }
    .to_string()
}

pub fn is_busy(code: i64) -> bool {
    matches!(code, 1 | 5 | 7 | 10 | 11 | 12 | 23)
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Suction { Silent = 0, Standard = 1, Strong = 2, Max = 3 }
impl Suction {
    pub fn from_raw(raw: i64) -> Option<Self> {
        [Self::Silent, Self::Standard, Self::Strong, Self::Max].into_iter().find(|s| *s as i64 == raw)
    }
    pub fn parse(text: &str) -> Option<Self> {
        match text { "silent" => Some(Self::Silent), "standard" => Some(Self::Standard), "strong" => Some(Self::Strong), "max" => Some(Self::Max), _ => None }
    }
    pub fn name(self) -> &'static str { ["Silent", "Standard", "Strong", "Max"][self as usize] }
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Mop { Low = 1, Medium = 2, High = 3 }
impl Mop {
    pub fn from_raw(raw: i64) -> Option<Self> {
        [Self::Low, Self::Medium, Self::High].into_iter().find(|s| *s as i64 == raw)
    }
    pub fn parse(text: &str) -> Option<Self> {
        match text { "low" => Some(Self::Low), "medium" => Some(Self::Medium), "high" => Some(Self::High), _ => None }
    }
    pub fn name(self) -> &'static str { ["Low", "Medium", "High"][self as usize - 1] }
}

/// Raw values for robots with mop lifting, where 0 and 2 are swapped compared to other Dreame models.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Mode { Vacuum = 2, VacuumAndMop = 0, Mop = 1, MopAfterVacuum = 3 }
impl Mode {
    pub fn from_raw(raw: i64) -> Option<Self> {
        [Self::Vacuum, Self::VacuumAndMop, Self::Mop, Self::MopAfterVacuum].into_iter().find(|s| *s as i64 == raw)
    }
    pub fn from_packed(packed: i64) -> Option<Self> { Self::from_raw(packed & 0x03) }
    pub fn packed_into(self, current: i64) -> i64 { (current & !0x03) | self as i64 }
    pub fn parse(text: &str) -> Option<Self> {
        match text { "vacuum" => Some(Self::Vacuum), "vacuum_and_mop" => Some(Self::VacuumAndMop), "mop" => Some(Self::Mop), "mop_after_vacuum" => Some(Self::MopAfterVacuum), _ => None }
    }
    pub fn name(self) -> &'static str {
        match self { Self::Vacuum => "Vacuuming", Self::VacuumAndMop => "Vacuuming and mopping", Self::Mop => "Mopping", Self::MopAfterVacuum => "Vacuuming before mopping" }
    }
}

/// How one room is cleaned (stored by the Mac app). A missing level means "whatever the robot is set to".
#[derive(Clone, Default, Deserialize, Serialize)]
pub struct RoomPreference {
    pub suction: Option<i64>,
    pub water: Option<i64>,
    pub mode: Option<i64>,
    #[serde(default = "one")]
    pub repeats: i64,
}
fn one() -> i64 { 1 }
pub const MAX_REPEATS: i64 = 3;

pub fn error_name(code: i64) -> String {
    crate::errors::name(code)
}
