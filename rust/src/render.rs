//! Draws the robot's map as a PNG, like the Mac app does: rooms in colors, walls, restricted zones, the robot
//! and its dock, with a legend of room numbers, names and sizes underneath.
use crate::map::{Cell, VacuumMap};

pub struct RoomLabel {
    pub id: u32,
    pub name: String,
    pub area_m2: f64,
}

pub struct Rendered {
    pub png: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

type Rgb = (u8, u8, u8);

/// Same palette as the Mac app (MapRenderer.roomColors).
pub const ROOM_COLORS: [Rgb; 8] = [
    (126, 179, 255), (255, 170, 120), (140, 220, 160), (240, 200, 110),
    (200, 160, 240), (120, 210, 220), (250, 150, 180), (190, 210, 120),
];
const WALL: Rgb = (80, 80, 85);
const FLOOR: Rgb = (200, 200, 205);
const TEXT: Rgb = (35, 35, 40);
const RED: Rgb = (226, 61, 71);
const BLUE: Rgb = (52, 120, 246);
const GREEN: Rgb = (46, 160, 67);

pub fn room_color(id: u32) -> Rgb {
    ROOM_COLORS[id as usize % ROOM_COLORS.len()]
}

struct Canvas {
    width: usize,
    height: usize,
    rgba: Vec<u8>,
}

impl Canvas {
    fn new(width: usize, height: usize) -> Self {
        Self { width, height, rgba: vec![255; width * height * 4] }
    }

    fn put(&mut self, x: i64, y: i64, color: Rgb, alpha: f64) {
        if x < 0 || y < 0 || x as usize >= self.width || y as usize >= self.height {
            return;
        }
        let i = (y as usize * self.width + x as usize) * 4;
        for (offset, channel) in [color.0, color.1, color.2].into_iter().enumerate() {
            self.rgba[i + offset] = (self.rgba[i + offset] as f64 * (1.0 - alpha) + channel as f64 * alpha).round() as u8;
        }
        self.rgba[i + 3] = 255;
    }

    fn fill_rect(&mut self, x: i64, y: i64, w: i64, h: i64, color: Rgb, alpha: f64) {
        for yy in y..y + h {
            for xx in x..x + w {
                self.put(xx, yy, color, alpha);
            }
        }
    }

    fn outline_rect(&mut self, x: i64, y: i64, w: i64, h: i64, thickness: i64, color: Rgb) {
        self.fill_rect(x, y, w, thickness, color, 1.0);
        self.fill_rect(x, y + h - thickness, w, thickness, color, 1.0);
        self.fill_rect(x, y, thickness, h, color, 1.0);
        self.fill_rect(x + w - thickness, y, thickness, h, color, 1.0);
    }

    fn line(&mut self, (x1, y1): (f64, f64), (x2, y2): (f64, f64), thickness: i64, color: Rgb) {
        let steps = ((x2 - x1).abs().max((y2 - y1).abs()).ceil() as usize).max(1);
        for step in 0..=steps {
            let t = step as f64 / steps as f64;
            let (x, y) = ((x1 + (x2 - x1) * t).round() as i64, (y1 + (y2 - y1) * t).round() as i64);
            self.fill_rect(x - thickness / 2, y - thickness / 2, thickness, thickness, color, 1.0);
        }
    }

    fn circle(&mut self, cx: f64, cy: f64, radius: f64, color: Rgb) {
        let r = radius.ceil() as i64;
        for dy in -r..=r {
            for dx in -r..=r {
                if ((dx * dx + dy * dy) as f64) <= radius * radius {
                    self.put(cx.round() as i64 + dx, cy.round() as i64 + dy, color, 1.0);
                }
            }
        }
    }

    /// Draws text (8x8 font, Latin letters with accents) and returns its width in pixels.
    fn text(&mut self, x: i64, y: i64, text: &str, scale: i64, color: Rgb) -> i64 {
        let mut cursor = x;
        for ch in text.chars() {
            let glyph = glyph(ch);
            for (row, bits) in glyph.iter().enumerate() {
                for col in 0..8 {
                    if bits >> col & 1 == 1 {
                        self.fill_rect(cursor + col * scale, y + row as i64 * scale, scale, scale, color, 1.0);
                    }
                }
            }
            cursor += 8 * scale;
        }
        cursor - x
    }
}

fn text_width(text: &str, scale: i64) -> i64 {
    text.chars().count() as i64 * 8 * scale
}

fn glyph(ch: char) -> [u8; 8] {
    font8x8::BASIC_UNICODE
        .iter()
        .chain(font8x8::LATIN_UNICODE.iter())
        .find(|f| f.0 == ch)
        .map(|f| f.1)
        .unwrap_or_else(|| font8x8::BASIC_UNICODE.iter().find(|f| f.0 == '?').map(|f| f.1).unwrap_or([0; 8]))
}

/// Extras for editing: a ruler in meters (the unit the room-editing tools use), a proposed dividing line and rooms to outline.
#[derive(Default, Clone)]
pub struct Options {
    pub grid: bool,
    /// Proposed dividing line in millimeters.
    pub line: Option<((f64, f64), (f64, f64))>,
    pub highlight: Vec<u32>,
}

#[cfg(test)]
pub fn render(map: &VacuumMap, rooms: &[RoomLabel]) -> Result<Rendered, String> {
    render_with(map, rooms, &Options::default())
}

const MAGENTA: Rgb = (200, 30, 190);
const GRID: Rgb = (60, 70, 170);

pub fn render_with(map: &VacuumMap, rooms: &[RoomLabel], options: &Options) -> Result<Rendered, String> {
    let (w, h) = (map.header.width, map.header.height);
    if w == 0 || h == 0 {
        return Err("The map is empty.".into());
    }
    let scale = (1600 / w.max(h)).clamp(2, 8);
    let (map_w, map_h) = (w * scale, h * scale);

    let has_robot = map.header.robot.is_some();
    let has_dock = map.header.charger.is_some();
    let mut keys: Vec<(&str, Rgb)> = vec![];
    if has_robot { keys.push(("Robot", RED)); }
    if has_dock { keys.push(("Dock", GREEN)); }
    if !map.zones.no_go.is_empty() { keys.push(("No-go zone", RED)); }
    if !map.zones.no_mop.is_empty() { keys.push(("No-mop zone", BLUE)); }
    if !map.zones.walls.is_empty() { keys.push(("Virtual wall", RED)); }
    if options.line.is_some() { keys.push(("Proposed dividing line", MAGENTA)); }
    if !options.highlight.is_empty() { keys.push(("Rooms to merge (outlined)", MAGENTA)); }
    if options.grid { keys.push(("Grid: every 1 m, numbers are meters", GRID)); }

    let mut sorted: Vec<&RoomLabel> = rooms.iter().collect();
    sorted.sort_by_key(|r| r.id);
    let row_h = 26;
    let legend_h = 16 + (sorted.len() + keys.len()) as i64 * row_h + 8;
    let longest = sorted.iter().map(|r| format!("{}  {}  {:.1} m2", r.id, r.name, r.area_m2).chars().count()).chain(keys.iter().map(|k| k.0.chars().count())).max().unwrap_or(0);
    let width = map_w.max(40 + longest * 16);
    let height = map_h + legend_h as usize;
    let mut canvas = Canvas::new(width, height);
    let offset_x = ((width - map_w) / 2) as i64;

    // map pixel (x right, y up) -> image coordinates
    let to_image = |mm: (f64, f64)| -> (f64, f64) {
        let px = (mm.0 - map.header.left as f64) / map.header.grid_size as f64;
        let py = (mm.1 - map.header.top as f64) / map.header.grid_size as f64;
        (offset_x as f64 + px * scale as f64, (h as f64 - py) * scale as f64)
    };

    for y in 0..h {
        for x in 0..w {
            let color = match map.cells[y * w + x] {
                Cell::Outside => continue,
                Cell::Wall => WALL,
                Cell::Floor => FLOOR,
                Cell::Room(id) => room_color(id),
            };
            canvas.fill_rect(offset_x + (x * scale) as i64, ((h - 1 - y) * scale) as i64, scale as i64, scale as i64, color, 1.0);
        }
    }

    if options.grid {
        let (left, top, grid) = (map.header.left as f64, map.header.top as f64, map.header.grid_size as f64);
        let (x_end, y_end) = (left + w as f64 * grid, top + h as f64 * grid);
        let (first_x, first_y) = ((left / 1000.0).ceil() as i64, (top / 1000.0).ceil() as i64);
        for m in first_x..=((x_end / 1000.0).floor() as i64) {
            let (x, _) = to_image((m as f64 * 1000.0, top));
            canvas.fill_rect(x as i64, 0, 1, map_h as i64, GRID, 0.35);
        }
        for m in first_y..=((y_end / 1000.0).floor() as i64) {
            let (_, y) = to_image((left, m as f64 * 1000.0));
            canvas.fill_rect(offset_x, y as i64, map_w as i64, 1, GRID, 0.35);
        }
        // numbers last so lines never cover them: x along the top edge, y along the left edge
        for m in first_x..=((x_end / 1000.0).floor() as i64) {
            let (x, _) = to_image((m as f64 * 1000.0, top));
            let label = m.to_string();
            canvas.fill_rect(x as i64 + 1, 0, text_width(&label, 2) + 2, 18, (255, 255, 255), 0.8);
            canvas.text(x as i64 + 2, 1, &label, 2, GRID);
        }
        for m in first_y..=((y_end / 1000.0).floor() as i64) {
            let (_, y) = to_image((left, m as f64 * 1000.0));
            let label = m.to_string();
            canvas.fill_rect(offset_x + 1, y as i64 - 17, text_width(&label, 2) + 2, 18, (255, 255, 255), 0.8);
            canvas.text(offset_x + 2, y as i64 - 16, &label, 2, GRID);
        }
    }

    for (zones, color) in [(&map.zones.no_go, RED), (&map.zones.no_mop, BLUE)] {
        for z in zones.iter() {
            let (a, b) = (to_image((z[0], z[1])), to_image((z[2], z[3])));
            let (x, y) = (a.0.min(b.0).round() as i64, a.1.min(b.1).round() as i64);
            let (rw, rh) = ((a.0 - b.0).abs().round() as i64, (a.1 - b.1).abs().round() as i64);
            canvas.fill_rect(x, y, rw, rh, color, 0.25);
            canvas.outline_rect(x, y, rw, rh, 2, color);
        }
    }
    for wall in &map.zones.walls {
        canvas.line(to_image((wall[0], wall[1])), to_image((wall[2], wall[3])), 3, RED);
    }

    for &id in &options.highlight {
        for y in 0..h {
            for x in 0..w {
                if map.cells[y * w + x] != Cell::Room(id) {
                    continue;
                }
                let same = |dx: i64, dy: i64| {
                    let (nx, ny) = (x as i64 + dx, y as i64 + dy);
                    nx >= 0 && ny >= 0 && (nx as usize) < w && (ny as usize) < h && map.cells[ny as usize * w + nx as usize] == Cell::Room(id)
                };
                let (ix, iy, s) = (offset_x + (x * scale) as i64, ((h - 1 - y) * scale) as i64, scale as i64);
                if !same(-1, 0) { canvas.fill_rect(ix, iy, 3, s, MAGENTA, 1.0); }
                if !same(1, 0) { canvas.fill_rect(ix + s - 3, iy, 3, s, MAGENTA, 1.0); }
                if !same(0, 1) { canvas.fill_rect(ix, iy, s, 3, MAGENTA, 1.0); }
                if !same(0, -1) { canvas.fill_rect(ix, iy + s - 3, s, 3, MAGENTA, 1.0); }
            }
        }
    }
    if let Some((a, b)) = options.line {
        let (a, b) = (to_image(a), to_image(b));
        canvas.line(a, b, 5, (255, 255, 255));
        canvas.line(a, b, 3, MAGENTA);
        canvas.circle(a.0, a.1, 5.0, MAGENTA);
        canvas.circle(b.0, b.1, 5.0, MAGENTA);
    }

    // Room numbers, placed on the room cell nearest to the room's center (so they stay inside odd shapes).
    for room in &sorted {
        let cells: Vec<(usize, usize)> = (0..h).flat_map(|y| (0..w).map(move |x| (x, y))).filter(|&(x, y)| map.cells[y * w + x] == Cell::Room(room.id)).collect();
        if cells.is_empty() {
            continue;
        }
        let (cx, cy) = (cells.iter().map(|c| c.0 as f64).sum::<f64>() / cells.len() as f64, cells.iter().map(|c| c.1 as f64).sum::<f64>() / cells.len() as f64);
        let (x, y) = *cells.iter().min_by(|a, b| {
            let d = |c: &&(usize, usize)| (c.0 as f64 - cx).powi(2) + (c.1 as f64 - cy).powi(2);
            d(a).partial_cmp(&d(b)).unwrap()
        }).unwrap();
        let label = room.id.to_string();
        let ts = (scale as i64 / 2).clamp(1, 3);
        let (ix, iy) = (offset_x + (x * scale) as i64 + scale as i64 / 2, ((h - 1 - y) * scale) as i64 + scale as i64 / 2);
        canvas.text(ix - text_width(&label, ts) / 2, iy - 4 * ts, &label, ts, TEXT);
    }

    if let Some(dock) = map.header.charger {
        let (x, y) = to_image(dock);
        let half = (3.0 * scale as f64) as i64; // bigger than the robot, so a docked robot sits inside it
        canvas.fill_rect(x as i64 - half - 2, y as i64 - half - 2, 2 * half + 4, 2 * half + 4, (255, 255, 255), 1.0);
        canvas.fill_rect(x as i64 - half, y as i64 - half, 2 * half, 2 * half, GREEN, 1.0);
    }
    if let Some(robot) = map.header.robot {
        let (x, y) = to_image(robot);
        canvas.circle(x, y, 2.2 * scale as f64 + 2.0, (255, 255, 255));
        canvas.circle(x, y, 2.2 * scale as f64, RED);
    }

    // Legend
    let mut y = map_h as i64 + 16;
    for room in &sorted {
        canvas.fill_rect(20, y, 18, 18, room_color(room.id), 1.0);
        canvas.outline_rect(20, y, 18, 18, 1, WALL);
        canvas.text(50, y + 1, &format!("{}  {}  {:.1} m2", room.id, room.name, room.area_m2), 2, TEXT);
        y += row_h;
    }
    for (name, color) in keys {
        canvas.fill_rect(20, y, 18, 18, color, 1.0);
        canvas.text(50, y + 1, name, 2, TEXT);
        y += row_h;
    }

    let mut png = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut png, width as u32, height as u32);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header().map_err(|e| e.to_string())?;
        writer.write_image_data(&canvas.rgba).map_err(|e| e.to_string())?;
        writer.finish().map_err(|e| e.to_string())?;
    }
    Ok(Rendered { png, width: width as u32, height: height as u32 })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::map::{Header, Zones};

    fn map() -> VacuumMap {
        // 12 x 8 cells of 50 mm: room 1 (left), room 2 (right), a wall frame around them.
        let (w, h) = (12usize, 8usize);
        let mut cells = vec![Cell::Outside; w * h];
        for y in 0..h {
            for x in 0..w {
                cells[y * w + x] = if x == 0 || y == 0 || x == w - 1 || y == h - 1 {
                    Cell::Wall
                } else if x < 6 {
                    Cell::Room(1)
                } else {
                    Cell::Room(2)
                };
            }
        }
        VacuumMap {
            header: Header { map_id: 0, robot: Some((100.0, 100.0)), charger: Some((450.0, 250.0)), width: w, height: h, grid_size: 50, left: 0, top: 0 },
            cells,
            zones: Zones { walls: vec![], no_go: vec![[200.0, 100.0, 300.0, 200.0]], no_mop: vec![] },
            saved_map_id: None,
            neighbors: Default::default(),
        }
    }

    fn decode(png_bytes: &[u8]) -> (png::OutputInfo, Vec<u8>) {
        let mut reader = png::Decoder::new(std::io::Cursor::new(png_bytes)).read_info().unwrap();
        let mut buffer = vec![0; reader.output_buffer_size().unwrap()];
        let info = reader.next_frame(&mut buffer).unwrap();
        (info, buffer)
    }

    fn rooms() -> Vec<RoomLabel> {
        vec![
            RoomLabel { id: 1, name: "Cozinha".into(), area_m2: 1.2 },
            RoomLabel { id: 2, name: "Sala".into(), area_m2: 1.2 },
        ]
    }

    #[test]
    fn renders_a_png_with_the_map_and_a_legend_below() {
        let rendered = render(&map(), &rooms()).unwrap();
        assert_eq!(&rendered.png[..8], b"\x89PNG\r\n\x1a\n");
        let (info, pixels) = decode(&rendered.png);
        assert_eq!((info.width, info.height), (rendered.width, rendered.height));
        let scale = 8usize; // 1600 / 12 is capped at 8
        assert!(info.height as usize > 8 * scale, "the legend adds rows under the map");

        // A cell inside room 1 away from the markers (map x=1, y=5) has room 1's color,
        // and the outer wall (x=0) is the wall color.
        let offset_x = (info.width as usize - 12 * scale) / 2;
        let color_at = |x: usize, y: usize| {
            let i = ((((8 - 1 - y) * scale) + 1) * info.width as usize + offset_x + x * scale + 1) * 4;
            (pixels[i], pixels[i + 1], pixels[i + 2])
        };
        assert_eq!(color_at(1, 5), room_color(1));
        assert_eq!(color_at(0, 7), WALL); // the robot marker covers the lower-left wall, so look at the top-left corner
    }

    #[test]
    fn the_legend_names_every_room_and_marker() {
        let rendered = render(&map(), &rooms()).unwrap();
        let (info, pixels) = decode(&rendered.png);
        // Legend swatches: a pixel of each room color exists below the map.
        let scale = 8usize;
        let below = &pixels[(8 * scale * info.width as usize * 4)..];
        let has = |c: Rgb| below.chunks(4).any(|p| (p[0], p[1], p[2]) == c);
        assert!(has(room_color(1)) && has(room_color(2)), "a swatch per room");
        assert!(has(RED) && has(GREEN), "robot and dock keys");
    }

    #[test]
    fn marks_the_robot_the_dock_and_zones_on_the_map() {
        let rendered = render(&map(), &rooms()).unwrap();
        let (info, pixels) = decode(&rendered.png);
        let scale = 8usize;
        let offset_x = (info.width as usize - 12 * scale) / 2;
        let at = |x: f64, y: f64| {
            let (ix, iy) = (offset_x + (x * scale as f64) as usize, ((8.0 - y) * scale as f64) as usize);
            let i = (iy * info.width as usize + ix) * 4;
            (pixels[i], pixels[i + 1], pixels[i + 2])
        };
        assert_eq!(at(2.0, 2.0), RED, "robot at (100 mm, 100 mm) = map pixel (2, 2)");
        assert_eq!(at(9.0, 5.0), GREEN, "dock at (450 mm, 250 mm) = map pixel (9, 5)");
        assert_ne!(at(5.0, 3.0), room_color(1), "the no-go zone tints the room under it");
    }

    #[test]
    fn accents_and_unknown_characters_do_not_break_labels() {
        let labels = vec![RoomLabel { id: 1, name: "Cozinha — açaí ☃".into(), area_m2: 1.0 }];
        assert!(render(&map(), &labels).is_ok());
    }

    #[test]
    fn hiding_a_room_crops_the_map_and_keeps_coordinates_aligned() {
        let hidden: std::collections::HashSet<u32> = [1].into();
        let cropped = map().hiding(&hidden);
        assert!(cropped.header.width < 12, "cropped to what is left");
        assert!(!cropped.room_ids().contains(&1));
        assert!(cropped.header.left > 0, "the origin moves with the crop");
        let rendered = render(&cropped, &rooms()[1..]).unwrap();
        assert_eq!(&rendered.png[..8], b"\x89PNG\r\n\x1a\n");
    }

    #[test]
    fn a_ruler_a_proposed_line_and_outlines_are_drawn_on_request() {
        let plain = render(&map(), &rooms()).unwrap();
        let with_all = render_with(
            &map(),
            &rooms(),
            &Options { grid: true, line: Some(((0.0, 100.0), (600.0, 100.0))), highlight: vec![1] },
        )
        .unwrap();
        assert!(with_all.width >= plain.width);
        assert!(with_all.height > plain.height, "and the legend explains the extras");
        let (_, pixels) = decode(&with_all.png);
        let has = |c: Rgb| pixels.chunks(4).any(|p| (p[0], p[1], p[2]) == c);
        assert!(has(MAGENTA), "the line and the outline");
        let (_, plain_pixels) = decode(&plain.png);
        assert!(!plain_pixels.chunks(4).any(|p| (p[0], p[1], p[2]) == MAGENTA), "nothing extra unless asked");
    }

    #[test]
    fn an_empty_map_is_an_error() {
        let mut empty = map();
        empty.header.width = 0;
        assert!(render(&empty, &[]).is_err());
    }

    /// Renders the real map when the (git-ignored) fixture is present, to look at the result.
    #[test]
    fn renders_the_real_map_if_available() {
        let Ok(text) = std::fs::read_to_string("../VacuumTests/Fixtures/map_raw.txt") else { return };
        let map = crate::map::decode(&text, Some("okzjB9uF4WCUU3d9")).unwrap();
        let labels: Vec<RoomLabel> = map.room_ids().into_iter().map(|id| RoomLabel { id, name: format!("Room {id}"), area_m2: map.area_of_room(id) }).collect();
        let rendered = render(&map, &labels).unwrap();
        if let Ok(dir) = std::env::var("VACUUMD_RENDER_OUT") {
            std::fs::write(dir, &rendered.png).unwrap();
        }
        assert!(rendered.width > 100 && rendered.height > rendered.width);
    }
}
