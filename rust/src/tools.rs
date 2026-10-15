//! The tools: one definition backs both the MCP tool and the plain `/v1/tools/{name}` call.
use crate::service::{self, RobotService, RoomEdit, ToolError};
use crate::spec::{self, Mode, Mop, Suction};
use serde_json::{json, Value};

pub struct Tool {
    pub name: &'static str,
    pub description: String,
    pub schema: Value,
    pub read_only: bool,
}

fn enum_schema(description: &str, options: &[&str]) -> Value {
    json!({"type": "string", "enum": options, "description": description})
}

fn suction_schema() -> Value {
    enum_schema("Suction power.", &["silent", "standard", "strong", "max"])
}
fn mop_schema() -> Value {
    enum_schema("Water level for mopping.", &["low", "medium", "high"])
}
fn mode_schema() -> Value {
    enum_schema(
        "What the robot does: vacuum only, vacuum and mop together, mop only, or mop after vacuuming.",
        &["vacuum", "vacuum_and_mop", "mop", "mop_after_vacuum"],
    )
}

pub fn list() -> Vec<Tool> {
    let none = json!({"type": "object", "properties": {}});
    let command = |name, description: &str| Tool { name, description: description.to_string(), schema: none.clone(), read_only: false };
    vec![
        Tool {
            name: "get_status",
            description: "The robot's current state: what it's doing, battery, any fault, suction/mop/mode settings, consumable wear and lifetime totals. Answers instantly from a reading at most a few seconds old.".into(),
            schema: json!({"type": "object", "properties": {"fresh": {"type": "boolean", "description": "Ask the robot again instead of using the last reading (slower)."}}}),
            read_only: true,
        },
        command("start_cleaning", "Start (or resume) cleaning the whole home with the current settings."),
        command("stop_cleaning", "Pause the current job. The robot stays where it is; use go_home to send it back to the dock."),
        command("go_home", "Send the robot back to its dock to charge."),
        command("locate", "Make the robot say \"I'm here\" so you can find it."),
        command("empty_bin", "Empty the robot's dust bin into the dock (the robot must be docked)."),
        Tool {
            name: "set_suction",
            description: "Set the suction power.".into(),
            schema: json!({"type": "object", "properties": {"level": suction_schema()}, "required": ["level"]}),
            read_only: false,
        },
        Tool {
            name: "set_mop_level",
            description: "Set how much water the mop uses.".into(),
            schema: json!({"type": "object", "properties": {"level": mop_schema()}, "required": ["level"]}),
            read_only: false,
        },
        Tool {
            name: "set_cleaning_mode",
            description: "Choose between vacuuming, mopping, or both.".into(),
            schema: json!({"type": "object", "properties": {"mode": mode_schema()}, "required": ["mode"]}),
            read_only: false,
        },
        Tool {
            name: "list_rooms",
            description: "The rooms on the robot's map, with ids, names, areas and any per-room settings saved in the Vacuum app.".into(),
            schema: none.clone(),
            read_only: true,
        },
        Tool {
            name: "get_map_image",
            description: "Draws the robot's map as a PNG picture and saves it in the user's Pictures/Vacuum folder, then returns the file path. Tell the user that path (or attach the file) so they can see it. The picture shows rooms with their numbers, a legend of room names and sizes, the robot, the dock and restricted zones. Rooms the user hid in the app stay hidden.".into(),
            schema: json!({"type": "object", "properties": {
                "fresh": {"type": "boolean", "description": "Download the map again so the robot's position is current (a few seconds). Default true; false reuses a map read in the last 10 minutes."},
                "grid": {"type": "boolean", "description": "Draw a ruler: lines every 1 m, numbered in meters (the unit merge_rooms/divide_room use). Default false."},
            }}),
            read_only: false,
        },
        Tool {
            name: "merge_rooms",
            description: "Merge two NEIGHBORING rooms into one, on the robot's saved map. This permanently changes the map and can only be undone by dividing again; room numbers may change afterwards. Without confirm: true nothing is changed: it returns a picture of what would happen. Show the user that picture and only call again with confirm: true after they agree. Returns the new room list.".into(),
            schema: json!({"type": "object", "properties": {
                "rooms": {"type": "array", "items": {"type": "integer"}, "minItems": 2, "maxItems": 2, "description": "The two room numbers (see list_rooms)."},
                "confirm": {"type": "boolean", "description": "true to really change the map. Default false = preview only."},
            }, "required": ["rooms"]}),
            read_only: false,
        },
        Tool {
            name: "divide_room",
            description: "Divide one room into two with a straight line, on the robot's saved map. The line is stretched to cross the whole room. Coordinates are in meters in the map's system (x right, y up), the same as boundsM from list_rooms and the grid from get_map_image(grid: true). The line must be at least 0.3 m long. This permanently changes the map; room numbers may change. Without confirm: true nothing is changed: it returns a picture with the line drawn. Show the user that picture and only call again with confirm: true after they agree. To move an area from one room to a neighbor: divide the room to cut the area off, then merge that piece into the neighbor.".into(),
            schema: json!({"type": "object", "properties": {
                "room": {"type": "integer", "description": "The room to divide (see list_rooms)."},
                "from": {"type": "object", "properties": {"x": {"type": "number"}, "y": {"type": "number"}}, "required": ["x", "y"], "description": "One end of the line, in meters."},
                "to": {"type": "object", "properties": {"x": {"type": "number"}, "y": {"type": "number"}}, "required": ["x", "y"], "description": "The other end, in meters."},
                "confirm": {"type": "boolean", "description": "true to really change the map. Default false = preview only."},
            }, "required": ["room", "from", "to"]}),
            read_only: false,
        },
        Tool {
            name: "clean_rooms",
            description: "Clean only the given rooms. Rooms can be named by id or by name (see list_rooms). Per-room settings saved in the app apply unless overridden here. All rooms in one job must use the same cleaning mode.".into(),
            schema: json!({"type": "object", "properties": {
                "rooms": {"type": "array", "items": {"type": ["string", "integer"]}, "minItems": 1, "description": "Room names or ids."},
                "suction": suction_schema(), "mop_level": mop_schema(), "mode": mode_schema(),
                "repeats": {"type": "integer", "minimum": 1, "maximum": spec::MAX_REPEATS, "description": "Passes per room."},
            }, "required": ["rooms"]}),
            read_only: false,
        },
        Tool {
            name: "drive",
            description: "Drive the robot by hand for a short time, then stop. Use small steps and check get_status between them. The first drive command of a session makes the robot announce remote control out loud.".into(),
            schema: json!({"type": "object", "properties": {
                "velocity": {"type": "integer", "minimum": -service::MAX_DRIVE_VELOCITY, "maximum": service::MAX_DRIVE_VELOCITY, "description": "Speed; positive is forward, negative is backward. 150 is slow, 300 normal, 600 fast."},
                "rotation": {"type": "integer", "minimum": -service::MAX_DRIVE_ROTATION, "maximum": service::MAX_DRIVE_ROTATION, "description": "Turn rate; positive turns left, negative turns right."},
                "duration_ms": {"type": "integer", "minimum": 100, "maximum": service::MAX_DRIVE_MILLISECONDS, "description": "How long to drive before stopping."},
            }, "required": ["duration_ms"]}),
            read_only: false,
        },
    ]
}

pub fn exists(name: &str) -> bool {
    list().iter().any(|t| t.name == name)
}

fn choice<T>(args: &Value, key: &str, parse: fn(&str) -> Option<T>, options: &str) -> Result<Option<T>, ToolError> {
    let Some(raw) = args.get(key).filter(|v| !v.is_null()) else { return Ok(None) };
    raw.as_str()
        .and_then(|text| parse(&text.to_lowercase().replace(' ', "_")))
        .map(Some)
        .ok_or_else(|| ToolError::new(format!("'{key}' must be one of: {options}.")))
}

fn number(args: &Value, key: &str) -> Result<Option<i64>, ToolError> {
    let Some(raw) = args.get(key).filter(|v| !v.is_null()) else { return Ok(None) };
    if let Some(n) = raw.as_i64() {
        return Ok(Some(n));
    }
    match raw.as_f64() {
        Some(f) if f == f.round() => Ok(Some(f as i64)),
        _ => Err(ToolError::new(format!("'{key}' must be a whole number."))),
    }
}

fn done(message: impl Into<String>) -> Value {
    json!({"ok": true, "message": message.into()})
}

pub async fn call(service: &RobotService, name: &str, args: &Value) -> Result<Value, ToolError> {
    let to_json = |v: &dyn erased::Ser| v.to_value();
    match name {
        "get_status" => Ok(to_json(&service.status(args["fresh"].as_bool().unwrap_or(false)).await)),
        "start_cleaning" => run(service, spec::START_CLEANING, "Cleaning started.").await,
        "stop_cleaning" => run(service, spec::STOP_CLEANING, "Stopped.").await,
        "go_home" => run(service, spec::GO_HOME, "Heading to the dock.").await,
        "locate" => run(service, spec::LOCATE, "The robot is announcing itself.").await,
        "empty_bin" => run(service, spec::EMPTY_BIN, "Emptying the bin.").await,
        "set_suction" => {
            let level = choice(args, "level", Suction::parse, "silent, standard, strong, max")?.ok_or_else(|| ToolError::new("'level' is required."))?;
            service.set_suction(level).await?;
            Ok(done(format!("Suction set to {}.", level.name())))
        }
        "set_mop_level" => {
            let level = choice(args, "level", Mop::parse, "low, medium, high")?.ok_or_else(|| ToolError::new("'level' is required."))?;
            service.set_mop(level).await?;
            Ok(done(format!("Mop water set to {}.", level.name())))
        }
        "set_cleaning_mode" => {
            let mode = choice(args, "mode", Mode::parse, "mop, mop_after_vacuum, vacuum, vacuum_and_mop")?.ok_or_else(|| ToolError::new("'mode' is required."))?;
            service.set_cleaning_mode(mode).await?;
            Ok(done(format!("Cleaning mode set to {}.", mode.name())))
        }
        "list_rooms" => Ok(to_json(&service.rooms().await?)),
        "get_map_image" => service.map_image(args["fresh"].as_bool().unwrap_or(true), args["grid"].as_bool().unwrap_or(false)).await,
        "merge_rooms" => {
            let ids = args["rooms"].as_array().filter(|l| l.len() == 2).ok_or_else(|| ToolError::new("'rooms' must be a list of exactly two room numbers."))?;
            let id = |v: &Value| v.as_u64().map(|n| n as u32).ok_or_else(|| ToolError::new("Room numbers must be whole numbers (see list_rooms)."));
            service.edit_rooms(RoomEdit::Merge(id(&ids[0])?, id(&ids[1])?), args["confirm"].as_bool().unwrap_or(false)).await
        }
        "divide_room" => {
            let room = number(args, "room")?.ok_or_else(|| ToolError::new("'room' is required."))? as u32;
            let mm = |key: &str| -> Result<(f64, f64), ToolError> {
                let p = &args[key];
                match (p["x"].as_f64(), p["y"].as_f64()) {
                    (Some(x), Some(y)) => Ok((x * 1000.0, y * 1000.0)),
                    _ => Err(ToolError::new(format!("'{key}' must be {{\"x\": meters, \"y\": meters}}, in the coordinates of boundsM / the picture's grid."))),
                }
            };
            service.edit_rooms(RoomEdit::Divide { room, from: mm("from")?, to: mm("to")? }, args["confirm"].as_bool().unwrap_or(false)).await
        }
        "clean_rooms" => {
            let list = args["rooms"].as_array().filter(|l| !l.is_empty()).ok_or_else(|| ToolError::new("'rooms' must be a non-empty list."))?;
            let refs: Vec<String> = list.iter().map(|v| v.as_str().map(String::from).unwrap_or_else(|| v.to_string())).collect();
            service
                .clean_rooms(
                    &refs,
                    choice(args, "suction", Suction::parse, "silent, standard, strong, max")?,
                    choice(args, "mop_level", Mop::parse, "low, medium, high")?,
                    choice(args, "mode", Mode::parse, "mop, mop_after_vacuum, vacuum, vacuum_and_mop")?,
                    number(args, "repeats")?,
                )
                .await?;
            Ok(done(format!("Cleaning {}.", refs.join(", "))))
        }
        "drive" => {
            let duration = number(args, "duration_ms")?.ok_or_else(|| ToolError::new("'duration_ms' is required."))?;
            service.drive(number(args, "velocity")?.unwrap_or(0), number(args, "rotation")?.unwrap_or(0), duration).await?;
            Ok(done(format!("Drove for {duration} ms and stopped.")))
        }
        _ => Err(ToolError::new(format!("Unknown tool '{name}'."))),
    }
}

async fn run(service: &RobotService, action: spec::Action, message: &str) -> Result<Value, ToolError> {
    service.run(action, vec![]).await?;
    Ok(done(message))
}

mod erased {
    pub trait Ser {
        fn to_value(&self) -> serde_json::Value;
    }
    impl<T: serde::Serialize> Ser for T {
        fn to_value(&self) -> serde_json::Value {
            serde_json::to_value(self).unwrap_or(serde_json::Value::Null)
        }
    }
}
