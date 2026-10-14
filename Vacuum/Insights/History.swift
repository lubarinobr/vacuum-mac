import CoreGraphics
import Foundation

/// One finished (or interrupted) clean, from the robot's history in Xiaomi's cloud (event 4.1).
///
/// Each event is a list of {piid, value}: 1 work mode, 2 minutes, 3 m², 13 completed (1) or not,
/// 8 start time, 9 clean-log file (its own map), 10 JSON with "area_clean_detail" = [[room, …], …].
struct CleanRecord: Codable, Identifiable, Equatable {
    var start: Date
    var minutes: Int
    var area: Int
    var completed: Bool
    var workMode: Int
    var rooms: [Int]
    var logFile: String?

    var id: Date { start }

    /// Work mode 18 is "clean selected rooms".
    var isRoomClean: Bool { workMode == 18 }

    init?(eventValue: String) {
        guard let items = try? JSONSerialization.jsonObject(with: Data(eventValue.utf8)) as? [[String: Any]] else { return nil }
        var fields: [Int: Any] = [:]
        for item in items {
            if let piid = item["piid"] as? Int { fields[piid] = item["value"] ?? item["val"] }
        }
        guard let startTime = fields[8] as? Int else { return nil }
        start = Date(timeIntervalSince1970: TimeInterval(startTime))
        minutes = fields[2] as? Int ?? 0
        area = fields[3] as? Int ?? 0
        completed = (fields[13] as? Int) == 1
        workMode = fields[1] as? Int ?? 0
        logFile = fields[9] as? String
        rooms = []
        if let extra = fields[10] as? String,
           let json = try? JSONSerialization.jsonObject(with: Data(extra.utf8)) as? [String: Any],
           let detail = json["area_clean_detail"] as? String,
           let list = try? JSONSerialization.jsonObject(with: Data(detail.utf8)) as? [[Int]] {
            rooms = list.compactMap(\.first)
        }
    }
}

/// Something that went wrong, recorded by this app while it was open (the robot doesn't keep these).
struct ProblemEvent: Codable, Identifiable, Equatable {
    var date: Date
    var code: Int
    /// Robot position in millimeters when it happened.
    var x: Double?
    var y: Double?
    var room: Int?

    var id: Date { date }
    var name: String { RobotErrors.name(code) }
    var isStuck: Bool { RobotErrors.stuckCodes.contains(code) }
    var position: CGPoint? { x.flatMap { x in y.map { CGPoint(x: x, y: $0) } } }
}

enum HistoryStore {
    private static let historyURL = AppStore.directory.appendingPathComponent("clean-history.json")
    private static let problemsURL = AppStore.directory.appendingPathComponent("problems.json")

    /// Cached history, newest first. Kept on this Mac so it grows beyond what the cloud keeps.
    static func loadHistory() -> [CleanRecord] { load(historyURL) ?? [] }

    /// Merges freshly downloaded records into the cache (same start time = same clean).
    static func merge(_ fresh: [CleanRecord]) -> [CleanRecord] {
        var byStart = Dictionary(loadHistory().map { ($0.start, $0) }, uniquingKeysWith: { a, _ in a })
        for record in fresh { byStart[record.start] = record }
        let merged = byStart.values.sorted { $0.start > $1.start }
        save(merged, to: historyURL)
        return merged
    }

    static func loadProblems() -> [ProblemEvent] { load(problemsURL) ?? [] }

    static func append(_ problem: ProblemEvent) {
        save(Array((loadProblems() + [problem]).suffix(1000)), to: problemsURL)
    }

    private static func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension XiaomiCloud {
    /// The robot's cleaning history (up to 300 most recent cleans the cloud still keeps).
    func cleanHistory(did: String) async throws -> [CleanRecord] {
        let reply = try await call("user/get_user_device_data", [
            "uid": session.userId, "did": did, "key": "4.1", "type": "event",
            "limit": 300, "time_start": 0, "time_end": 9_999_999_999,
        ])
        let events = reply["result"] as? [[String: Any]] ?? []
        return events.compactMap { ($0["value"] as? String).flatMap(CleanRecord.init(eventValue:)) }
    }
}

/// Numbers for the Insights window, computed from the history.
struct InsightsSummary {
    struct Week: Identifiable {
        let start: Date
        let cleans: Int
        let area: Int
        let minutes: Int
        var id: Date { start }
    }

    struct RoomStat: Identifiable {
        let room: Int
        let cleans: Int
        let lastCleaned: Date?
        var id: Int { room }
    }

    let weeks: [Week]          // oldest first, last one is this week
    let rooms: [RoomStat]
    let recent: [CleanRecord]

    var thisWeek: Week? { weeks.last }
    var lastWeek: Week? { weeks.dropLast().last }

    init(history: [CleanRecord], rooms visibleRooms: [Int], now: Date = .now, calendar: Calendar = .current, weekCount: Int = 8) {
        let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        weeks = (0..<weekCount).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -back, to: thisWeekStart),
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { return nil }
            let inWeek = history.filter { $0.start >= start && $0.start < end && $0.minutes > 0 }
            return Week(start: start, cleans: inWeek.count, area: inWeek.reduce(0) { $0 + $1.area },
                        minutes: inWeek.reduce(0) { $0 + $1.minutes })
        }
        let monthAgo = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        rooms = visibleRooms.map { room in
            let cleansWithRoom = history.filter { $0.rooms.contains(room) && $0.minutes > 0 }
            return RoomStat(room: room,
                            cleans: cleansWithRoom.filter { $0.start >= monthAgo }.count,
                            lastCleaned: cleansWithRoom.map(\.start).max())
        }
        recent = Array(history.filter { $0.minutes > 0 }.prefix(10))
    }
}
