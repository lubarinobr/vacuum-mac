import AppKit
import CoreGraphics

enum MapRenderer {
    static let roomColors: [(UInt8, UInt8, UInt8)] = [
        (126, 179, 255), (255, 170, 120), (140, 220, 160), (240, 200, 110),
        (200, 160, 240), (120, 210, 220), (250, 150, 180), (190, 210, 120),
    ]

    /// Light paints the map like paper; dark like a screen at night: deep floor, pale walls, rooms a touch deeper.
    enum Style: Sendable {
        case light, dark

        var wall: (UInt8, UInt8, UInt8) { self == .dark ? (150, 155, 165) : (80, 80, 85) }
        var floor: (UInt8, UInt8, UInt8) { self == .dark ? (44, 46, 52) : (200, 200, 205) }

        func room(_ id: Int) -> (UInt8, UInt8, UInt8) {
            let (r, g, b) = MapRenderer.roomColors[id % MapRenderer.roomColors.count]
            guard self == .dark else { return (r, g, b) }
            return (UInt8(Double(r) * 0.8), UInt8(Double(g) * 0.8), UInt8(Double(b) * 0.8))
        }

        /// Unselected rooms while a selection exists: washed out by day, sunk into the floor by night.
        func dimmed(_ c: (UInt8, UInt8, UInt8)) -> (UInt8, UInt8, UInt8) {
            self == .dark ? (c.0 / 3 + 34, c.1 / 3 + 34, c.2 / 3 + 38) : (c.0 / 2 + 100, c.1 / 2 + 100, c.2 / 2 + 100)
        }

        /// The outline of a lifted room: darker by day, a bright lit rim by night.
        func edge(_ c: (UInt8, UInt8, UInt8)) -> (UInt8, UInt8, UInt8) {
            guard self == .dark else { return (c.0 / 2, c.1 / 2, c.2 / 2) }
            func lift(_ v: UInt8) -> UInt8 { UInt8(min(255, Int(v) + 55)) }
            return (lift(c.0), lift(c.1), lift(c.2))
        }
    }

    static func color(forRoom id: Int) -> NSColor {
        let (r, g, b) = roomColors[id % roomColors.count]
        return NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// One image pixel per map pixel, flipped so north is up. Unselected rooms are dimmed while a selection exists.
    static func image(_ map: VacuumMap, selected: Set<Int>, style: Style = .light) -> CGImage? {
        let width = map.width, height = map.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color: (UInt8, UInt8, UInt8, UInt8)
                switch map.cell(x: x, y: y) {
                case .outside: color = (0, 0, 0, 0)
                case .wall: color = (style.wall.0, style.wall.1, style.wall.2, 255)
                case .floor: color = (style.floor.0, style.floor.1, style.floor.2, 255)
                case .room(let id):
                    let base = style.room(id)
                    let c = !selected.isEmpty && !selected.contains(id) ? style.dimmed(base) : base
                    color = (c.0, c.1, c.2, 255)
                }
                let index = ((height - 1 - y) * width + x) * 4
                rgba[index] = color.0
                rgba[index + 1] = color.1
                rgba[index + 2] = color.2
                rgba[index + 3] = color.3
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Just one room, same size as the full map image (transparent elsewhere), with an outline.
    /// Used to "lift" a selected room above the rest of the map.
    static func roomImage(_ map: VacuumMap, room id: Int, style: Style = .light) -> CGImage? {
        let width = map.width, height = map.height
        let fill = style.room(id), rim = style.edge(fill)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width where map.cell(x: x, y: y) == .room(id) {
                let edge = [(1, 0), (-1, 0), (0, 1), (0, -1)].contains { map.cell(x: x + $0.0, y: y + $0.1) != .room(id) }
                let index = ((height - 1 - y) * width + x) * 4
                let c = edge ? rim : fill
                rgba[index] = c.0
                rgba[index + 1] = c.1
                rgba[index + 2] = c.2
                rgba[index + 3] = 255
            }
        }
        return makeImage(rgba, width: width, height: height)
    }

    private static func makeImage(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    struct RoomStats {
        var centers: [Int: CGPoint] = [:]
        var areas: [Int: Double] = [:]
    }

    /// Centers (image coordinates, origin top-left) and areas (m²) of all rooms, in one pass.
    static func roomStats(_ map: VacuumMap) -> RoomStats {
        var sums: [Int: (x: Double, y: Double, count: Double)] = [:]
        let width = map.width, height = map.height
        for index in map.cells.indices {
            guard case .room(let id) = map.cells[index] else { continue }
            let x = index % width, y = index / width
            let s = sums[id] ?? (0, 0, 0)
            sums[id] = (s.x + Double(x), s.y + Double(height - 1 - y), s.count + 1)
        }
        let cellArea = Double(map.header.gridSize * map.header.gridSize) / 1_000_000
        var stats = RoomStats()
        for (id, s) in sums {
            stats.centers[id] = CGPoint(x: s.x / s.count, y: s.y / s.count)
            stats.areas[id] = s.count * cellArea
        }
        return stats
    }

    /// Center of each room in image coordinates (origin top-left).
    static func roomCenters(_ map: VacuumMap) -> [Int: CGPoint] {
        var sums: [Int: (Double, Double, Double)] = [:]
        for y in 0..<map.height {
            for x in 0..<map.width {
                if case .room(let id) = map.cell(x: x, y: y) {
                    let s = sums[id] ?? (0, 0, 0)
                    sums[id] = (s.0 + Double(x), s.1 + Double(map.height - 1 - y), s.2 + 1)
                }
            }
        }
        return sums.mapValues { CGPoint(x: $0.0 / $0.2, y: $0.1 / $0.2) }
    }
}
