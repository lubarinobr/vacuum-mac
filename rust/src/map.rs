//! Dreame map file format, as decoded by Tasshack/dreame-vacuum (DreameVacuumMapDecoder):
//! base64url -> AES-256-CBC (if the object name carried a key) -> zlib ->
//!   27-byte header + width*height pixel bytes + JSON with extra data.
//! Only what the agent tools need is kept: the room layout and each room's area.
use crate::crypto;
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde_json::Value;
use std::collections::BTreeSet;

const HEADER_SIZE: usize = 27;
/// AES IV for xiaomi.vacuum.c102gl map files (dreame-vacuum DEVICE_INFO, key index 6).
const X20_PLUS_IV: &[u8; 16] = b"OFULk9To37qRdXY3";

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Cell {
    Outside,
    Wall,
    Floor,
    Room(u32),
}

#[derive(Clone, Debug)]
pub struct Header {
    pub map_id: i64,
    /// Robot and charger positions in millimeters (same coordinates as zones).
    pub robot: Option<(f64, f64)>,
    pub charger: Option<(f64, f64)>,
    pub width: usize,
    pub height: usize,
    pub grid_size: i64, // millimeters per pixel
    pub left: i64,
    pub top: i64,
}

/// Restricted areas in millimeters: x1, y1, x2, y2.
#[derive(Clone, Default, Debug)]
pub struct Zones {
    pub walls: Vec<[f64; 4]>,
    pub no_go: Vec<[f64; 4]>,
    pub no_mop: Vec<[f64; 4]>,
}

pub struct VacuumMap {
    pub header: Header,
    /// Row-major, row 0 is the bottom of the map.
    pub cells: Vec<Cell>,
    pub zones: Zones,
    /// ID of the robot's saved map; room merge/divide commands must target it.
    pub saved_map_id: Option<i64>,
    /// Which rooms touch each other (from the saved map's "seg_inf"); only neighbors can be merged.
    pub neighbors: std::collections::HashMap<u32, std::collections::HashSet<u32>>,
}

/// A rectangle in millimeters: min x, min y, max x, max y.
pub type Bounds = [f64; 4];

/// Stretches a line (same direction) so it spans the whole box plus a margin on each side.
/// Returns the line unchanged if it doesn't point through the box. (Liang–Barsky, like the Mac app.)
pub fn extend_line(a: (f64, f64), b: (f64, f64), bounds: Bounds, margin: f64) -> ((f64, f64), (f64, f64)) {
    let (min_x, min_y, max_x, max_y) = (bounds[0] - margin, bounds[1] - margin, bounds[2] + margin, bounds[3] + margin);
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    if dx == 0.0 && dy == 0.0 {
        return (a, b);
    }
    let (mut t0, mut t1) = (f64::MIN, f64::MAX);
    for (p, q) in [(-dx, a.0 - min_x), (dx, max_x - a.0), (-dy, a.1 - min_y), (dy, max_y - a.1)] {
        if p == 0.0 {
            if q < 0.0 {
                return (a, b);
            }
        } else {
            let t = q / p;
            if p < 0.0 { t0 = t0.max(t) } else { t1 = t1.min(t) }
        }
    }
    if t0 > t1 {
        return (a, b);
    }
    ((a.0 + t0 * dx, a.1 + t0 * dy), (a.0 + t1 * dx, a.1 + t1 * dy))
}

impl VacuumMap {
    pub fn room_ids(&self) -> Vec<u32> {
        let ids: BTreeSet<u32> = self.cells.iter().filter_map(|c| if let Cell::Room(id) = c { Some(*id) } else { None }).collect();
        ids.into_iter().collect()
    }

    /// Bounding box of a room in millimeters (min x, min y, max x, max y), in the robot's coordinates.
    pub fn room_bounds(&self, id: u32) -> Option<Bounds> {
        let w = self.header.width;
        let (mut min_x, mut min_y, mut max_x, mut max_y) = (usize::MAX, usize::MAX, 0usize, 0usize);
        let mut found = false;
        for (i, cell) in self.cells.iter().enumerate() {
            if *cell == Cell::Room(id) {
                let (x, y) = (i % w, i / w);
                (min_x, max_x, min_y, max_y) = (min_x.min(x), max_x.max(x), min_y.min(y), max_y.max(y));
                found = true;
            }
        }
        if !found {
            return None;
        }
        let g = self.header.grid_size as f64;
        Some([
            self.header.left as f64 + min_x as f64 * g,
            self.header.top as f64 + min_y as f64 * g,
            self.header.left as f64 + (max_x + 1) as f64 * g,
            self.header.top as f64 + (max_y + 1) as f64 * g,
        ])
    }

    pub fn area_of_room(&self, id: u32) -> f64 {
        let count = self.cells.iter().filter(|c| **c == Cell::Room(id)).count() as f64;
        let mm = self.header.grid_size as f64;
        count * mm * mm / 1_000_000.0
    }

    /// The map without some rooms: their cells, plus walls that only border them, become empty,
    /// and the result is cropped to what's left (header origin adjusted to match). Same as the Mac app.
    pub fn hiding(&self, hidden: &std::collections::HashSet<u32>) -> VacuumMap {
        let keep = |m: &VacuumMap| VacuumMap { header: m.header.clone(), cells: m.cells.clone(), zones: m.zones.clone(), saved_map_id: m.saved_map_id, neighbors: m.neighbors.clone() };
        if hidden.is_empty() {
            return keep(self);
        }
        let (width, height) = (self.header.width as i64, self.header.height as i64);
        let visible_room = |x: i64, y: i64| match self.cell(x, y) {
            Cell::Room(id) => !hidden.contains(&id),
            other => other == Cell::Floor,
        };
        let mut filtered = self.cells.clone();
        for y in 0..height {
            for x in 0..width {
                let index = (y * width + x) as usize;
                match self.cells[index] {
                    Cell::Room(id) if hidden.contains(&id) => filtered[index] = Cell::Outside,
                    Cell::Wall => {
                        let near_visible = (-1..=1).any(|dy| (-1..=1).any(|dx| visible_room(x + dx, y + dy)));
                        if !near_visible {
                            filtered[index] = Cell::Outside;
                        }
                    }
                    _ => {}
                }
            }
        }
        let (mut min_x, mut min_y, mut max_x, mut max_y) = (width, height, -1, -1);
        for y in 0..height {
            for x in 0..width {
                if filtered[(y * width + x) as usize] != Cell::Outside {
                    (min_x, max_x) = (min_x.min(x), max_x.max(x));
                    (min_y, max_y) = (min_y.min(y), max_y.max(y));
                }
            }
        }
        if max_x < min_x {
            return keep(self);
        }
        let pad = 4;
        let (min_x, min_y) = ((min_x - pad).max(0), (min_y - pad).max(0));
        let (max_x, max_y) = ((max_x + pad).min(width - 1), (max_y + pad).min(height - 1));
        let mut cropped = Vec::with_capacity(((max_x - min_x + 1) * (max_y - min_y + 1)) as usize);
        for y in min_y..=max_y {
            cropped.extend_from_slice(&filtered[(y * width + min_x) as usize..=(y * width + max_x) as usize]);
        }
        let mut header = self.header.clone();
        header.width = (max_x - min_x + 1) as usize;
        header.height = (max_y - min_y + 1) as usize;
        header.left += min_x * header.grid_size;
        header.top += min_y * header.grid_size;
        VacuumMap { header, cells: cropped, zones: self.zones.clone(), saved_map_id: self.saved_map_id, neighbors: self.neighbors.clone() }
    }

    fn cell(&self, x: i64, y: i64) -> Cell {
        if x < 0 || y < 0 || x as usize >= self.header.width || y as usize >= self.header.height {
            return Cell::Outside;
        }
        self.cells[y as usize * self.header.width + x as usize]
    }
}

fn le_i16(raw: &[u8], at: usize) -> i64 {
    i16::from_le_bytes([raw[at], raw[at + 1]]) as i64
}
fn le_u16(raw: &[u8], at: usize) -> i64 {
    u16::from_le_bytes([raw[at], raw[at + 1]]) as i64
}

/// Decodes a map file as downloaded from the cloud. `key` comes from the object name ("name,key").
pub fn decode(raw_text: &str, key: Option<&str>) -> Result<VacuumMap, String> {
    parse(&inflate(raw_text, key)?)
}

fn inflate(raw_text: &str, key: Option<&str>) -> Result<Vec<u8>, String> {
    let mut text = raw_text.trim().replace('_', "/").replace('-', "+");
    let mut key = key.map(String::from);
    if key.is_none() {
        if let Some(comma) = text.find(',') {
            key = Some(text[comma + 1..].to_string());
            text.truncate(comma);
        }
    }
    while text.len() % 4 != 0 {
        text.push('=');
    }
    let mut data = B64.decode(&text).map_err(|_| "The map file isn't valid base64.".to_string())?;
    if let Some(key) = key.filter(|k| !k.is_empty()) {
        let digest = hex::encode(crypto::sha256(key.as_bytes()));
        let aes_key: [u8; 32] = digest.as_bytes()[..32].try_into().unwrap();
        data = crypto::aes256_decrypt_raw(&data, &aes_key, X20_PLUS_IV)?;
    }
    crypto::zlib_decompress(&data)
}

fn parse_header(raw: &[u8]) -> Result<Header, String> {
    if raw.len() < HEADER_SIZE {
        return Err("The map file is too short.".into());
    }
    let position = |x: usize| Some((le_i16(raw, x) as f64, le_i16(raw, x + 2) as f64));
    Ok(Header {
        map_id: le_u16(raw, 0),
        robot: position(5),
        charger: position(11),
        grid_size: le_u16(raw, 17).max(1),
        width: le_u16(raw, 19) as usize,
        height: le_u16(raw, 21) as usize,
        left: le_i16(raw, 23),
        top: le_i16(raw, 25),
    })
}

struct Live {
    header: Header,
    cells: Vec<Cell>,
    extra: Value,
}

/// Which rooms touch each other: "seg_inf": {"<room>": {"nei_id": [rooms]}}.
fn neighbors_from(extra: &Value) -> std::collections::HashMap<u32, std::collections::HashSet<u32>> {
    let mut result = std::collections::HashMap::new();
    for (key, room) in extra["seg_inf"].as_object().into_iter().flatten() {
        let Ok(id) = key.parse::<u32>() else { continue };
        let touching = room["nei_id"].as_array().into_iter().flatten().filter_map(|n| n.as_u64()).map(|n| n as u32).collect();
        result.insert(id, touching);
    }
    result
}

/// Zones live in "vw": lines are virtual walls, "rect" no-go areas, "mop" no-mop areas.
fn zones_from(vw: &Value) -> Zones {
    let list = |key: &str| -> Vec<[f64; 4]> {
        vw[key]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|item| {
                let n: Vec<f64> = item.as_array()?.iter().filter_map(|v| v.as_f64()).collect();
                (n.len() >= 4).then(|| [n[0], n[1], n[2], n[3]])
            })
            .collect()
    };
    Zones { walls: list("line"), no_go: list("rect"), no_mop: list("mop") }
}

fn parse_live(raw: &[u8]) -> Result<Live, String> {
    let mut header = parse_header(raw)?;
    let pixels_end = HEADER_SIZE + header.width * header.height;
    if raw.len() < pixels_end {
        return Err("The map file is too short.".into());
    }
    let pixels = &raw[HEADER_SIZE..pixels_end];
    let extra: Value = serde_json::from_slice(&raw[pixels_end..]).unwrap_or(Value::Null);
    if let Some(origin) = extra["origin"].as_array().filter(|o| o.len() > 1) {
        header.left = origin[0].as_i64().unwrap_or(header.left);
        header.top = origin[1].as_i64().unwrap_or(header.top);
    }
    let newer = ["saveMapId", "cover", "diff", "curtain"].iter().any(|k| !extra[*k].is_null());
    let cells = pixels.iter().map(|p| if newer { newer_cell(*p) } else { older_cell(*p) }).collect();
    Ok(Live { header, cells, extra })
}

fn parse(raw: &[u8]) -> Result<VacuumMap, String> {
    let live = parse_live(raw)?;
    let saved_raw = live.extra["rism"].as_str().and_then(|s| inflate(s, Some("")).ok());
    // The live map usually carries zones only inside "rism" (the robot's saved map).
    let saved_extra = saved_raw.as_deref().and_then(|r| parse_live(r).ok()).map(|l| l.extra);
    let zones = if live.extra["vw"].is_object() {
        zones_from(&live.extra["vw"])
    } else {
        saved_extra.as_ref().map_or_else(Zones::default, |e| zones_from(&e["vw"]))
    };

    // Rooms come from the saved map: it's the robot's official room layout (used for room cleaning
    // and what the Xiaomi app draws), while the live map's room labels are rough and go blank right
    // after a room edit.
    if let Some(saved_raw) = saved_raw {
        if let Ok(saved_header) = parse_header(&saved_raw) {
            let mut saved_header = saved_header;
            let saved_map_id = Some(saved_header.map_id);
            let neighbors = neighbors_from(saved_extra.as_ref().unwrap_or(&Value::Null));
            // Robot and charger positions come from the live map, like the layout of rooms comes from the saved one.
            saved_header.robot = live.header.robot;
            saved_header.charger = live.header.charger;
            let pixels_end = HEADER_SIZE + saved_header.width * saved_header.height;
            if saved_raw.len() >= pixels_end {
                let pixels = &saved_raw[HEADER_SIZE..pixels_end];
                let mut cells = saved_cells(pixels, saved_header.width, saved_header.height);
                if live.cells.iter().any(|c| *c != Cell::Outside) {
                    let live_map = VacuumMap { header: live.header.clone(), cells: live.cells.clone(), zones: Zones::default(), saved_map_id: None, neighbors: Default::default() };
                    cells = overlay_live_detail(cells, &saved_header, &live_map);
                }
                return Ok(VacuumMap { header: saved_header, cells, zones, saved_map_id, neighbors });
            }
        }
    }
    let neighbors = neighbors_from(&live.extra);
    Ok(VacuumMap { header: live.header, cells: live.cells, zones, saved_map_id: None, neighbors })
}

/// Brings back what the live map sees inside rooms (furniture, obstacles, walls).
/// Both grids are 5 cm; they're aligned by their origins.
fn overlay_live_detail(saved: Vec<Cell>, saved_header: &Header, live: &VacuumMap) -> Vec<Cell> {
    let grid = saved_header.grid_size;
    if grid != live.header.grid_size {
        return saved;
    }
    let dx = (saved_header.left - live.header.left) / grid;
    let dy = (saved_header.top - live.header.top) / grid;
    let mut cells = saved;
    for y in 0..saved_header.height {
        for x in 0..saved_header.width {
            let index = y * saved_header.width + x;
            if !matches!(cells[index], Cell::Room(_)) {
                continue;
            }
            let (lx, ly) = (x as i64 + dx, y as i64 + dy);
            if lx < 0 || ly < 0 || lx as usize >= live.header.width || ly as usize >= live.header.height {
                continue;
            }
            match live.cell(lx, ly) {
                Cell::Outside => cells[index] = Cell::Outside,
                Cell::Wall => cells[index] = Cell::Wall,
                _ => {}
            }
        }
    }
    cells
}

/// Saved-map pixels: room number in the low bits (1...60), top bit = carpet. No walls are stored,
/// so room cells that touch the outside are drawn as walls.
fn saved_cells(pixels: &[u8], width: usize, height: usize) -> Vec<Cell> {
    let room = |x: i64, y: i64| -> u32 {
        if x < 0 || y < 0 || x as usize >= width || y as usize >= height {
            return 0;
        }
        (pixels[y as usize * width + x as usize] & 0x3F) as u32
    };
    let mut cells = vec![Cell::Outside; width * height];
    for y in 0..height as i64 {
        for x in 0..width as i64 {
            let id = room(x, y);
            if id == 0 {
                continue;
            }
            let edge = room(x + 1, y) == 0 || room(x - 1, y) == 0 || room(x, y + 1) == 0 || room(x, y - 1) == 0;
            cells[y as usize * width + x as usize] = if edge {
                Cell::Wall
            } else if id >= 61 {
                Cell::Floor
            } else {
                Cell::Room(id)
            };
        }
    }
    cells
}

fn older_cell(pixel: u8) -> Cell {
    match pixel >> 2 {
        0 => Cell::Outside,
        63 => Cell::Wall,
        61 | 62 => Cell::Floor,
        segment => Cell::Room(segment as u32),
    }
}

fn newer_cell(pixel: u8) -> Cell {
    if pixel == 0 {
        return Cell::Outside;
    }
    let segment = (pixel & 0x1F) as u32;
    let wall = (pixel >> 5) & 0x03;
    if wall == 1 || wall == 2 {
        return Cell::Wall;
    }
    if segment == 0 || segment == 31 { Cell::Floor } else { Cell::Room(segment) }
}

#[cfg(test)]
mod geometry_tests {
    use super::*;

    #[test]
    fn extends_a_short_line_across_the_whole_box() {
        let line = extend_line((400.0, 200.0), (600.0, 200.0), [0.0, 0.0, 1000.0, 400.0], 100.0);
        assert_eq!(line, ((-100.0, 200.0), (1100.0, 200.0)));
    }

    #[test]
    fn keeps_the_drawn_angle() {
        let line = extend_line((400.0, 400.0), (600.0, 600.0), [0.0, 0.0, 1000.0, 1000.0], 0.0);
        assert_eq!(line, ((0.0, 0.0), (1000.0, 1000.0)));
    }

    #[test]
    fn a_line_that_misses_the_box_is_left_alone() {
        let line = extend_line((0.0, 2000.0), (100.0, 2000.0), [0.0, 0.0, 1000.0, 400.0], 100.0);
        assert_eq!(line, ((0.0, 2000.0), (100.0, 2000.0)));
        let dot = extend_line((5.0, 5.0), (5.0, 5.0), [0.0, 0.0, 10.0, 10.0], 0.0);
        assert_eq!(dot, ((5.0, 5.0), (5.0, 5.0)));
    }

    #[test]
    fn room_bounds_are_in_millimeters_from_the_map_origin() {
        let (w, h) = (4usize, 3usize);
        let mut cells = vec![Cell::Outside; w * h];
        cells[1 * w + 1] = Cell::Room(2); // x=1, y=1
        cells[1 * w + 2] = Cell::Room(2); // x=2, y=1
        let map = VacuumMap {
            header: Header { map_id: 0, robot: None, charger: None, width: w, height: h, grid_size: 50, left: -100, top: 20 },
            cells,
            zones: Zones::default(),
            saved_map_id: None,
            neighbors: Default::default(),
        };
        assert_eq!(map.room_bounds(2), Some([-50.0, 70.0, 50.0, 120.0]));
        assert_eq!(map.room_bounds(9), None);
    }

    #[test]
    fn the_real_corridor_is_tall_and_narrow() {
        let Ok(text) = std::fs::read_to_string("../VacuumTests/Fixtures/map_raw.txt") else { return };
        let map = decode(&text, Some("okzjB9uF4WCUU3d9")).unwrap();
        let b = map.room_bounds(6).unwrap();
        assert!(b[2] - b[0] > 0.0 && (b[3] - b[1]) > (b[2] - b[0]));
        assert_eq!(map.saved_map_id, Some(12), "the saved map id the app also reads");
        assert_eq!(map.neighbors[&6], [1, 2, 3, 4, 5].into_iter().collect());
        assert_eq!(map.neighbors[&2], [4, 6].into_iter().collect());
    }
}
