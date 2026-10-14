import CommonCrypto
import CoreGraphics
import Foundation

// Dreame map file format, as decoded by Tasshack/dreame-vacuum (DreameVacuumMapDecoder):
// base64url -> AES-256-CBC (if the object name carried a key) -> zlib ->
//   27-byte header + width*height pixel bytes + JSON with extra data.

struct VacuumMap {
    struct Header {
        var mapID: Int
        var frameID: Int
        var frameType: Int
        var robot: CGPoint, robotAngle: Int
        var charger: CGPoint, chargerAngle: Int
        var gridSize: Int  // millimeters per pixel
        var width: Int
        var height: Int
        var left: Int     // millimeters
        var top: Int
    }

    enum Cell: Equatable {
        case outside, wall, floor, room(Int)
    }

    /// Restricted areas, in millimeters (same coordinates as the robot position).
    struct Zones {
        var virtualWalls: [(CGPoint, CGPoint)] = []
        var noGo: [CGRect] = []
        var noMop: [CGRect] = []
        var carpets: [CGRect] = []

        var isEmpty: Bool { virtualWalls.isEmpty && noGo.isEmpty && noMop.isEmpty }
    }

    /// One point of the robot's driven path, in millimeters.
    struct PathPoint: Equatable {
        var point: CGPoint
        /// True when the robot "jumped" here (start of a new stroke) instead of driving from the previous point.
        var startsStroke: Bool
    }

    let header: Header
    /// Row-major, row 0 is the bottom of the map.
    let cells: [Cell]
    let extra: [String: Any]
    var zones = Zones()
    var path: [PathPoint] = []
    /// Computed once, since scanning every cell is too slow to repeat on each redraw.
    let roomIDs: [Int]

    init(header: Header, cells: [Cell], extra: [String: Any], zones: Zones = Zones(), path: [PathPoint] = []) {
        self.header = header
        self.cells = cells
        self.extra = extra
        self.zones = zones
        self.path = path
        var ids = Set<Int>()
        for cell in cells { if case .room(let id) = cell { ids.insert(id) } }
        self.roomIDs = ids.sorted()
    }
    /// ID of the robot's saved map; room merge/divide commands must target it.
    var savedMapID: Int?
    /// Which rooms touch each other (from the saved map's "seg_inf"); only neighbors can be merged.
    var roomNeighbors: [Int: Set<Int>] = [:]

    var width: Int { header.width }
    var height: Int { header.height }

    func cell(x: Int, y: Int) -> Cell {
        guard x >= 0, y >= 0, x < width, y < height else { return .outside }
        return cells[y * width + x]
    }

    func area(ofRoom id: Int) -> Double {
        let mmPerPixel = Double(header.gridSize)
        let count = cells.lazy.filter { $0 == .room(id) }.count
        return Double(count) * mmPerPixel * mmPerPixel / 1_000_000
    }

    /// Map pixel (x right, y up) for a position in millimeters.
    func pixel(for position: CGPoint) -> CGPoint {
        CGPoint(x: (position.x - CGFloat(header.left)) / CGFloat(header.gridSize),
                y: (position.y - CGFloat(header.top)) / CGFloat(header.gridSize))
    }
}

extension VacuumMap {
    /// The map without some rooms: their cells, plus walls and obstacles that only border them,
    /// become empty, and the result is cropped to what's left (header origin adjusted to match).
    func hiding(rooms hidden: Set<Int>) -> VacuumMap {
        guard !hidden.isEmpty else { return self }
        func visibleRoom(_ x: Int, _ y: Int) -> Bool {
            if case .room(let id) = cell(x: x, y: y) { return !hidden.contains(id) }
            return cell(x: x, y: y) == .floor
        }
        var filtered = cells
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                switch cells[index] {
                case .room(let id) where hidden.contains(id):
                    filtered[index] = .outside
                case .wall:
                    let nearVisible = (-1...1).contains { dy in (-1...1).contains { dx in visibleRoom(x + dx, y + dy) } }
                    if !nearVisible { filtered[index] = .outside }
                default:
                    break
                }
            }
        }

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where filtered[y * width + x] != .outside {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return self }
        let pad = 4
        minX = max(0, minX - pad); minY = max(0, minY - pad)
        maxX = min(width - 1, maxX + pad); maxY = min(height - 1, maxY + pad)

        var cropped: [Cell] = []
        cropped.reserveCapacity((maxX - minX + 1) * (maxY - minY + 1))
        for y in minY...maxY { cropped.append(contentsOf: filtered[(y * width + minX)...(y * width + maxX)]) }
        var newHeader = header
        newHeader.width = maxX - minX + 1
        newHeader.height = maxY - minY + 1
        newHeader.left += minX * header.gridSize
        newHeader.top += minY * header.gridSize
        var result = VacuumMap(header: newHeader, cells: cropped, extra: extra, zones: zones, path: path)
        result.savedMapID = savedMapID
        result.roomNeighbors = roomNeighbors
        return result
    }
}

enum MapDecodeError: Error, LocalizedError {
    case invalidBase64, tooShort

    var errorDescription: String? {
        switch self {
        case .invalidBase64: "The map file isn't valid base64."
        case .tooShort: "The map file is too short."
        }
    }
}

enum MapDecoder {
    static let headerSize = 27
    /// AES IV for xiaomi.vacuum.c102gl map files (dreame-vacuum DEVICE_INFO, key index 6).
    static let x20PlusIV = Data("OFULk9To37qRdXY3".utf8)

    static func decode(_ rawText: String, key: String?, iv: Data = x20PlusIV) throws -> VacuumMap {
        try parse(inflate(rawText, key: key, iv: iv))
    }

    /// A live frame (usually a small partial "P" frame): just the header and its extra data.
    /// Its pixels are a diff against earlier frames, so they are not used.
    static func decodeFrame(_ rawText: String, key: String?, iv: Data = x20PlusIV) throws -> (header: VacuumMap.Header, extra: [String: Any]) {
        let raw = try inflate(rawText, key: key, iv: iv)
        let header = try parseHeader(raw)
        let pixelsEnd = headerSize + header.width * header.height
        let extra = raw.count > pixelsEnd
            ? (try? JSONSerialization.jsonObject(with: raw[(raw.startIndex + pixelsEnd)...])) as? [String: Any] ?? [:]
            : [:]
        return (header, extra)
    }

    /// Robot path ("tr"): M/W/S/l x,y are absolute points, L x,y is a step from the previous point.
    /// "l" continues the path of the previous frame, so it does not start a new stroke.
    static func path(from trace: String, continuingFrom last: CGPoint? = nil) -> [VacuumMap.PathPoint] {
        guard let regex = try? NSRegularExpression(pattern: #"([MWSLl])(-?\d+),(-?\d+)"#) else { return [] }
        var current = last ?? .zero
        var points: [VacuumMap.PathPoint] = []
        let text = trace as NSString
        for match in regex.matches(in: trace, range: NSRange(location: 0, length: text.length)) {
            let op = text.substring(with: match.range(at: 1))
            let x = CGFloat(Int(text.substring(with: match.range(at: 2))) ?? 0)
            let y = CGFloat(Int(text.substring(with: match.range(at: 3))) ?? 0)
            switch op {
            case "L":
                current = CGPoint(x: current.x + x, y: current.y + y)
                points.append(.init(point: current, startsStroke: false))
            case "l":
                current = CGPoint(x: x, y: y)
                points.append(.init(point: current, startsStroke: last == nil))
            default:
                current = CGPoint(x: x, y: y)
                points.append(.init(point: current, startsStroke: true))
            }
        }
        return points
    }

    private static func inflate(_ rawText: String, key: String?, iv: Data) throws -> Data {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "-", with: "+")
        var key = key
        if key == nil, let comma = text.firstIndex(of: ",") {
            key = String(text[text.index(after: comma)...])
            text = String(text[..<comma])
        }
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard var data = Data(base64Encoded: text) else { throw MapDecodeError.invalidBase64 }

        if let key, !key.isEmpty {
            let hexDigest = Crypto.sha256(Data(key.utf8)).hex
            let aesKey = Data(hexDigest.prefix(32).utf8)
            data = try Crypto.aesCBC(CCOperation(kCCDecrypt), data, key: aesKey, iv: iv, padding: false)
        }
        return try Crypto.zlibDecompress(data)
    }

    private static func parseHeader(_ raw: Data) throws -> VacuumMap.Header {
        guard raw.count >= headerSize else { throw MapDecodeError.tooShort }
        func i16(_ offset: Int) -> Int { Int(raw.readLittleEndian(Int16.self, at: offset)) }
        func u16(_ offset: Int) -> Int { Int(raw.readLittleEndian(UInt16.self, at: offset)) }
        return VacuumMap.Header(
            mapID: u16(0), frameID: u16(2), frameType: Int(raw[raw.startIndex + 4]),
            robot: CGPoint(x: i16(5), y: i16(7)), robotAngle: i16(9),
            charger: CGPoint(x: i16(11), y: i16(13)), chargerAngle: i16(15),
            gridSize: max(u16(17), 1), width: u16(19), height: u16(21), left: i16(23), top: i16(25))
    }

    static func parse(_ raw: Data) throws -> VacuumMap {
        var map = try parseLive(raw)
        let savedRaw = (map.extra["rism"] as? String).flatMap { try? inflate($0, key: "", iv: x20PlusIV) }
        let saved = savedRaw.flatMap { try? parseLive($0) }
        map.savedMapID = saved?.header.mapID
        map.roomNeighbors = neighbors(in: saved?.extra ?? map.extra)

        // Rooms come from the saved map: it's the robot's official room layout (used for room cleaning
        // and what the Xiaomi app draws), while the live map's room labels are rough and go blank right
        // after a room edit. Robot/charger positions and the path still come from the live map.
        if let savedRaw, let savedHeader = try? parseHeader(savedRaw) {
            var header = savedHeader
            header.robot = map.header.robot
            header.robotAngle = map.header.robotAngle
            header.charger = map.header.charger
            header.chargerAngle = map.header.chargerAngle
            header.mapID = map.header.mapID
            header.frameID = map.header.frameID
            let pixelsEnd = headerSize + header.width * header.height
            if savedRaw.count >= pixelsEnd {
                let pixels = savedRaw[(savedRaw.startIndex + headerSize)..<(savedRaw.startIndex + pixelsEnd)]
                var cells = savedCells(Array(pixels), width: header.width, height: header.height)
                if map.cells.contains(where: { $0 != .outside }) {
                    cells = overlayLiveDetail(on: cells, savedHeader: header, live: map)
                }
                var restored = VacuumMap(header: header, cells: cells,
                                         extra: map.extra, zones: map.zones, path: map.path)
                restored.savedMapID = map.savedMapID
                restored.roomNeighbors = map.roomNeighbors
                return restored
            }
        }
        return map
    }

    /// Brings back what the live map sees inside rooms (furniture like a sofa, obstacles, walls),
    /// which the saved floor plan fills in. Both grids are 5 cm; they're aligned by their origins.
    static func overlayLiveDetail(on saved: [VacuumMap.Cell], savedHeader: VacuumMap.Header, live: VacuumMap) -> [VacuumMap.Cell] {
        let grid = savedHeader.gridSize
        guard grid == live.header.gridSize else { return saved }
        let dx = (savedHeader.left - live.header.left) / grid
        let dy = (savedHeader.top - live.header.top) / grid
        var cells = saved
        for y in 0..<savedHeader.height {
            for x in 0..<savedHeader.width {
                let index = y * savedHeader.width + x
                guard case .room = cells[index] else { continue }
                let lx = x + dx, ly = y + dy
                guard lx >= 0, ly >= 0, lx < live.width, ly < live.height else { continue }
                switch live.cell(x: lx, y: ly) {
                case .outside: cells[index] = .outside   // e.g. under the sofa
                case .wall: cells[index] = .wall         // obstacles and walls the robot detected
                default: break
                }
            }
        }
        return cells
    }

    /// Saved-map pixels: room number in the low bits (1...60), top bit = carpet. No walls are stored,
    /// so room cells that touch the outside are drawn as walls.
    static func savedCells(_ pixels: [UInt8], width: Int, height: Int) -> [VacuumMap.Cell] {
        func room(_ x: Int, _ y: Int) -> Int {
            guard x >= 0, y >= 0, x < width, y < height else { return 0 }
            return Int(pixels[y * width + x] & 0x3F)
        }
        var cells = [VacuumMap.Cell](repeating: .outside, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let id = room(x, y)
                guard id > 0 else { continue }
                let edge = room(x + 1, y) == 0 || room(x - 1, y) == 0 || room(x, y + 1) == 0 || room(x, y - 1) == 0
                cells[y * width + x] = edge ? .wall : (id >= 61 ? .floor : .room(id))
            }
        }
        return cells
    }

    private static func parseLive(_ raw: Data) throws -> VacuumMap {
        var header = try parseHeader(raw)

        let pixelsEnd = headerSize + header.width * header.height
        guard raw.count >= pixelsEnd else { throw MapDecodeError.tooShort }
        let pixels = raw[(raw.startIndex + headerSize)..<(raw.startIndex + pixelsEnd)]
        let extra = (try? JSONSerialization.jsonObject(with: raw[(raw.startIndex + pixelsEnd)...])) as? [String: Any] ?? [:]

        if let origin = extra["origin"] as? [Int], origin.count > 1 {
            header.left = origin[0]
            header.top = origin[1]
        }

        let newerFormat = ["saveMapId", "cover", "diff", "curtain"].contains { extra[$0] != nil }
        let cells = pixels.map { newerFormat ? newerCell($0) : olderCell($0) }
        return VacuumMap(header: header, cells: cells, extra: extra, zones: zones(in: extra),
                         path: (extra["tr"] as? String).map { path(from: $0) } ?? [])
    }

    static func neighbors(in extra: [String: Any]) -> [Int: Set<Int>] {
        guard let info = extra["seg_inf"] as? [String: Any] else { return [:] }
        var result: [Int: Set<Int>] = [:]
        for (key, value) in info {
            guard let id = Int(key), let room = value as? [String: Any] else { continue }
            result[id] = Set((room["nei_id"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue })
        }
        return result
    }

    /// Zones live in "vw". The live map usually only carries them inside "rism",
    /// the robot's saved map embedded as another (unencrypted) map file.
    static func zones(in extra: [String: Any]) -> VacuumMap.Zones {
        if let vw = extra["vw"] as? [String: Any] { return zones(from: vw) }
        if let rism = extra["rism"] as? String, let saved = try? decode(rism, key: "") {
            return saved.zones
        }
        return VacuumMap.Zones()
    }

    static func zones(from vw: [String: Any]) -> VacuumMap.Zones {
        func numbers(_ key: String) -> [[Double]] {
            (vw[key] as? [[Any]] ?? []).map { $0.compactMap { ($0 as? NSNumber)?.doubleValue } }
        }
        func rects(_ key: String) -> [CGRect] {
            numbers(key).filter { $0.count >= 4 }.map {
                CGRect(x: min($0[0], $0[2]), y: min($0[1], $0[3]), width: abs($0[2] - $0[0]), height: abs($0[3] - $0[1]))
            }
        }
        return VacuumMap.Zones(
            virtualWalls: numbers("line").filter { $0.count >= 4 }.map { (CGPoint(x: $0[0], y: $0[1]), CGPoint(x: $0[2], y: $0[3])) },
            noGo: rects("rect"),
            noMop: rects("mop"),
            carpets: rects("addcpt"))
    }

    private static func olderCell(_ pixel: UInt8) -> VacuumMap.Cell {
        let segment = Int(pixel >> 2)
        switch segment {
        case 0: return .outside
        case 63: return .wall
        case 61, 62: return .floor
        default: return .room(segment)
        }
    }

    private static func newerCell(_ pixel: UInt8) -> VacuumMap.Cell {
        guard pixel > 0 else { return .outside }
        let segment = Int(pixel & 0x1F)
        let wall = (pixel >> 5) & 0x03
        if wall == 1 || wall == 2 { return .wall }
        return segment == 0 || segment == 31 ? .floor : .room(segment)
    }
}
