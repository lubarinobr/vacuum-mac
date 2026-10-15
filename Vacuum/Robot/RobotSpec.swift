import Foundation

// MIoT spec for xiaomi.vacuum.c102gl (Xiaomi Robot Vacuum X20+), from miot-spec.org.
// Each property/action is addressed by (siid, piid) or (siid, aiid).

struct PropertyID: Hashable {
    let siid: Int
    let piid: Int
}

struct ActionID {
    let siid: Int
    let aiid: Int
}

enum Spec {
    static let status = PropertyID(siid: 2, piid: 1)
    static let fault = PropertyID(siid: 2, piid: 2)
    static let suction = PropertyID(siid: 2, piid: 3)
    static let battery = PropertyID(siid: 3, piid: 1)
    static let chargingState = PropertyID(siid: 3, piid: 2)
    static let workMode = PropertyID(siid: 4, piid: 1)
    static let cleaningTime = PropertyID(siid: 4, piid: 2)
    static let cleaningArea = PropertyID(siid: 4, piid: 3)
    static let mopLevel = PropertyID(siid: 4, piid: 5)
    /// Packed value: bits 0-1 = cleaning mode, higher bytes = mop-washing settings (dreame-vacuum CLEANING_MODE).
    static let cleanSetting = PropertyID(siid: 4, piid: 23)
    static let mainBrush = PropertyID(siid: 9, piid: 2)
    static let sideBrush = PropertyID(siid: 10, piid: 2)
    static let filter = PropertyID(siid: 11, piid: 1)
    static let mopPad = PropertyID(siid: 18, piid: 1)
    static let dndEnabled = PropertyID(siid: 5, piid: 1)
    static let dndStart = PropertyID(siid: 5, piid: 2)
    static let dndEnd = PropertyID(siid: 5, piid: 3)
    static let schedules = PropertyID(siid: 8, piid: 2)
    /// Manual driving: a JSON string {"spdv": velocity, "spdw": rotation, "audio": "true|false", "random": n} (dreame-vacuum).
    static let remoteControl = PropertyID(siid: 4, piid: 15)
    static let totalCleaningMinutes = PropertyID(siid: 12, piid: 2)
    static let totalCleans = PropertyID(siid: 12, piid: 3)
    static let totalArea = PropertyID(siid: 12, piid: 4)

    static let polled: [PropertyID] = [
        status, fault, suction, battery, chargingState, workMode, cleaningTime, cleaningArea, mopLevel, cleanSetting,
        mainBrush, sideBrush, filter, mopPad, dndEnabled, dndStart, dndEnd, schedules,
        totalCleaningMinutes, totalCleans, totalArea,
    ]

    static let startCleaning = ActionID(siid: 2, aiid: 1)
    static let stopCleaning = ActionID(siid: 2, aiid: 2)
    static let emptyBin = ActionID(siid: 2, aiid: 4)
    static let goHome = ActionID(siid: 3, aiid: 1)
    static let locate = ActionID(siid: 7, aiid: 1)
    static let deleteSchedule = ActionID(siid: 8, aiid: 1)
    static let resetMainBrush = ActionID(siid: 9, aiid: 1)
    static let resetSideBrush = ActionID(siid: 10, aiid: 1)
    static let resetFilter = ActionID(siid: 11, aiid: 1)
    static let resetMopPad = ActionID(siid: 18, aiid: 1)
    static let scheduleIDPiid = 3
    static let requestMap = ActionID(siid: 6, aiid: 1)
    static let mapFrameInfoPiid = 2
    static let mapObjectNamePiid = 3

    /// Room cleaning, as dreame-vacuum does it: start-clean with work-mode 18 and the room list.
    static let startCustomClean = ActionID(siid: 4, aiid: 1)
    static let segmentCleaningWorkMode = 18
    static let cleanExtendDataPiid = 10

    static let statusNames: [Int: String] = [
        1: "Sweeping", 2: "Idle", 3: "Paused", 4: "Error", 5: "Going home", 6: "Charging", 7: "Mopping",
        8: "Drying mop", 9: "Washing mop", 10: "Going to wash", 11: "Building map", 12: "Sweeping and mopping",
        13: "Fully charged", 14: "Updating", 19: "Checking water", 21: "Mop wash paused", 22: "Emptying bin",
        23: "Remote control",
    ]

    static let busyStatuses: Set<Int> = [1, 5, 7, 10, 11, 12, 23]
}

enum SuctionLevel: Int, CaseIterable, Identifiable {
    case silent = 0, basic, strong, fullSpeed
    var id: Int { rawValue }
    var name: String { ["Silent", "Standard", "Strong", "Max"][rawValue] }
}

/// Raw values for robots with mop lifting, where 0 and 2 are swapped compared to other Dreame models.
/// Confirmed on the X20+: the Xiaomi app showed "Vacuum" while the robot reported 2.
enum CleaningMode: Int, CaseIterable, Identifiable {
    // Same names and order as the Xiaomi Home app.
    case vacuum = 2, vacuumAndMop = 0, mop = 1, mopAfterVacuum = 3
    var id: Int { rawValue }
    var name: String {
        switch self {
        case .vacuum: "Vacuuming"
        case .vacuumAndMop: "Vacuuming and mopping"
        case .mop: "Mopping"
        case .mopAfterVacuum: "Vacuuming before mopping"
        }
    }

    init?(packed: Int) { self.init(rawValue: packed & 0x03) }

    func packed(into current: Int) -> Int { (current & ~0x03) | rawValue }
}

enum MopLevel: Int, CaseIterable, Identifiable {
    case low = 1, medium, high
    var id: Int { rawValue }
    var name: String { ["Low", "Medium", "High"][rawValue - 1] }
}

/// How one room is cleaned. A nil level means "whatever the robot is set to right now".
struct RoomPreference: Codable, Equatable {
    var suction: Int?
    var water: Int?
    var mode: Int?  // CleaningMode raw value
    var repeats = 1

    static let maxRepeats = 3
    var isDefault: Bool { suction == nil && water == nil && mode == nil && repeats == 1 }
}
