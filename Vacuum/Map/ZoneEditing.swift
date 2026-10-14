import CoreGraphics
import Foundation

/// A restricted zone being edited. Points are in millimeters, like the robot uses.
struct EditableZone: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Codable {
        case wall, noGo, noMop

        var name: String {
            switch self {
            case .wall: "Wall"
            case .noGo: "No-go"
            case .noMop: "No-mop"
            }
        }

        var systemImage: String {
            switch self {
            case .wall: "line.diagonal"
            case .noGo: "nosign"
            case .noMop: "drop.triangle"
            }
        }
    }

    let id: UUID
    var kind: Kind
    var a: CGPoint
    var b: CGPoint

    init(id: UUID = UUID(), kind: Kind, a: CGPoint, b: CGPoint) {
        self.id = id
        self.kind = kind
        self.a = a
        self.b = b
    }

    var rect: CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Big enough to keep after drawing (walls 20 cm long, zones 20 cm on each side).
    var isUsable: Bool {
        kind == .wall ? hypot(b.x - a.x, b.y - a.y) >= 200 : (rect.width >= 200 && rect.height >= 200)
    }
}

enum ZoneEditing {
    static func editable(from zones: VacuumMap.Zones) -> [EditableZone] {
        zones.virtualWalls.map { EditableZone(kind: .wall, a: $0.0, b: $0.1) }
            + zones.noGo.map { EditableZone(kind: .noGo, a: CGPoint(x: $0.minX, y: $0.minY), b: CGPoint(x: $0.maxX, y: $0.maxY)) }
            + zones.noMop.map { EditableZone(kind: .noMop, a: CGPoint(x: $0.minX, y: $0.minY), b: CGPoint(x: $0.maxX, y: $0.maxY)) }
    }

    static func zones(from editable: [EditableZone], keepingCarpetsOf original: VacuumMap.Zones) -> VacuumMap.Zones {
        var zones = VacuumMap.Zones(carpets: original.carpets)
        for zone in editable {
            switch zone.kind {
            case .wall: zones.virtualWalls.append((zone.a, zone.b))
            case .noGo: zones.noGo.append(zone.rect)
            case .noMop: zones.noMop.append(zone.rect)
            }
        }
        return zones
    }

    /// The "vw" object for the robot's update-map command: the complete set, in whole millimeters.
    static func payload(for zones: VacuumMap.Zones) -> [String: [[Int]]] {
        func rect(_ r: CGRect) -> [Int] { [Int(r.minX.rounded()), Int(r.minY.rounded()), Int(r.maxX.rounded()), Int(r.maxY.rounded())] }
        return [
            "line": zones.virtualWalls.map { [Int($0.0.x.rounded()), Int($0.0.y.rounded()), Int($0.1.x.rounded()), Int($0.1.y.rounded())] },
            "rect": zones.noGo.map(rect),
            "mop": zones.noMop.map(rect),
        ]
    }
}

/// Converts between map millimeters and points in the on-screen map view.
struct MapTransform {
    let map: VacuumMap
    let scale: CGFloat

    func view(_ mm: CGPoint) -> CGPoint {
        let pixel = map.pixel(for: mm)
        return CGPoint(x: pixel.x * scale, y: (CGFloat(map.height - 1) - pixel.y) * scale)
    }

    /// A length in millimeters, in view points.
    func points(_ mm: Double) -> CGFloat {
        CGFloat(mm) / CGFloat(map.header.gridSize) * scale
    }

    func mm(_ view: CGPoint) -> CGPoint {
        let grid = CGFloat(map.header.gridSize)
        return CGPoint(x: view.x / scale * grid + CGFloat(map.header.left),
                       y: (CGFloat(map.height - 1) - view.y / scale) * grid + CGFloat(map.header.top))
    }

    func viewRect(_ zone: EditableZone) -> CGRect {
        let a = view(zone.a), b = view(zone.b)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Handles a selected zone can be resized by: the two wall ends, or the four rectangle corners.
    func handles(_ zone: EditableZone) -> [CGPoint] {
        if zone.kind == .wall { return [view(zone.a), view(zone.b)] }
        let r = viewRect(zone)
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    func contains(_ zone: EditableZone, _ point: CGPoint, tolerance: CGFloat = 8) -> Bool {
        if zone.kind == .wall {
            return distance(from: point, toSegment: view(zone.a), view(zone.b)) <= tolerance
        }
        return viewRect(zone).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }

    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

enum RoomGeometry {
    /// Bounding box of a room, in millimeters.
    static func bounds(ofRoom id: Int, in map: VacuumMap) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in 0..<map.height {
            for x in 0..<map.width where map.cell(x: x, y: y) == .room(id) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        let grid = CGFloat(map.header.gridSize)
        return CGRect(x: CGFloat(map.header.left) + CGFloat(minX) * grid,
                      y: CGFloat(map.header.top) + CGFloat(minY) * grid,
                      width: CGFloat(maxX - minX + 1) * grid,
                      height: CGFloat(maxY - minY + 1) * grid)
    }

    /// Stretches a line (same direction) so it spans the whole box plus a margin on each side.
    /// Returns the line unchanged if it doesn't point through the box.
    static func extend(_ line: (CGPoint, CGPoint), across box: CGRect?, margin: CGFloat) -> (CGPoint, CGPoint) {
        guard let box = box?.insetBy(dx: -margin, dy: -margin) else { return line }
        let (a, b) = line
        let dx = b.x - a.x, dy = b.y - a.y
        guard dx != 0 || dy != 0 else { return line }
        // Liang–Barsky: range of t where a + t·(b − a) is inside the box.
        var t0 = -CGFloat.greatestFiniteMagnitude, t1 = CGFloat.greatestFiniteMagnitude
        for (p, q) in [(-dx, a.x - box.minX), (dx, box.maxX - a.x), (-dy, a.y - box.minY), (dy, box.maxY - a.y)] {
            if p == 0 {
                if q < 0 { return line }
            } else {
                let t = q / p
                if p < 0 { t0 = max(t0, t) } else { t1 = min(t1, t) }
            }
        }
        guard t0 <= t1 else { return line }
        return (CGPoint(x: a.x + t0 * dx, y: a.y + t0 * dy), CGPoint(x: a.x + t1 * dx, y: a.y + t1 * dy))
    }
}
