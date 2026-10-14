import Foundation

/// One scheduled clean, as stored in the robot's "timer-clean" property (8.2).
///
/// Schedules are separated by ";". Each one is "id-state-HH:MM-days-repeat-map-suction-water-rooms",
/// e.g. "1-1-08:36-0100000-1-12-1-0-6" = schedule 1, on, 08:36, Mondays, weekly, map 12,
/// Standard suction, water 0, room 6. Field meanings follow dreame-vacuum and were confirmed by
/// editing a schedule in the Xiaomi app and reading it back.
struct CleaningSchedule: Identifiable, Equatable {
    var id: Int
    var isEnabled: Bool
    var hour: Int
    var minute: Int
    /// Sunday first, like the robot stores them.
    var days: [Bool]
    var mapID: String
    var suction: Int
    /// Kept as the robot gave it; its scale isn't documented, so edits don't change it.
    var water: Int
    /// Empty means the whole house.
    var rooms: [Int]

    static let dayLetters = ["S", "M", "T", "W", "T", "F", "S"]
    static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    /// Display order: Monday first.
    static let displayDayOrder = [1, 2, 3, 4, 5, 6, 0]

    var repeats: Bool { days.contains(true) }

    var timeText: String { String(format: "%02d:%02d", hour, minute) }

    var daysText: String {
        let selected = days.indices.filter { days[$0] }
        switch selected {
        case []: return "Once"
        case Array(0...6): return "Every day"
        case [1, 2, 3, 4, 5]: return "Weekdays"
        case [0, 6]: return "Weekends"
        default: return Self.displayDayOrder.filter { days[$0] }.map { Self.dayNames[$0] }.joined(separator: ", ")
        }
    }

    /// Next time this schedule will run after `date`, or nil if it's off.
    func nextRun(after date: Date, calendar: Calendar = .current) -> Date? {
        guard isEnabled else { return nil }
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date)),
                  let run = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  run > date else { continue }
            let weekdayIndex = calendar.component(.weekday, from: run) - 1  // Sunday = 0, like `days`
            if !repeats || days[weekdayIndex] { return run }
        }
        return nil
    }

    static func parseAll(_ value: String) -> [CleaningSchedule] {
        value.split(separator: ";").compactMap { parse(String($0)) }
            .sorted { ($0.hour, $0.minute, $0.id) < ($1.hour, $1.minute, $1.id) }
    }

    static func parse(_ text: String) -> CleaningSchedule? {
        let fields = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 9, let id = Int(fields[0]) else { return nil }
        let time = fields[2].split(separator: ":").compactMap { Int($0) }
        let dayFlags = Array(fields[3].padding(toLength: 7, withPad: "0", startingAt: 0)).prefix(7).map { $0 == "1" }
        return CleaningSchedule(
            id: id,
            isEnabled: fields[1] == "1" || fields[1] == "2",
            hour: time.first ?? 0,
            minute: time.count > 1 ? time[1] : 0,
            days: dayFlags,
            mapID: fields[5],
            suction: Int(fields[6]) ?? 1,
            water: Int(fields[7]) ?? 0,
            rooms: fields[8] == "0" ? [] : fields[8].split(separator: ",").compactMap { Int($0) })
    }

    var encoded: String {
        [
            String(id),
            isEnabled ? "1" : "0",
            timeText,
            days.map { $0 ? "1" : "0" }.joined(),
            repeats ? "1" : "0",
            mapID,
            String(suction),
            String(water),
            rooms.isEmpty ? "0" : rooms.sorted().map(String.init).joined(separator: ","),
        ].joined(separator: "-")
    }

    static func encodeAll(_ schedules: [CleaningSchedule]) -> String {
        schedules.sorted { $0.id < $1.id }.map(\.encoded).joined(separator: ";")
    }
}
