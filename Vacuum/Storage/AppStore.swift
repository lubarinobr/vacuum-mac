import Foundation

/// Files in ~/Library/Application Support/Vacuum, readable only by you (permissions 600): room names,
/// furniture, history and so on. Nothing here leaves this Mac. The robot token and the Xiaomi login are
/// not here: vacuumd keeps them, and the app asks it.
enum AppStore {
    static let directory: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vacuum", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let roomNamesURL = directory.appendingPathComponent("room-names.json")
    private static let zoneBackupsURL = directory.appendingPathComponent("zone-backups.json")

    struct ZoneBackup: Codable {
        var date: Date
        var vw: [String: [[Int]]]
    }

    /// Zones as they were before each save, newest last (keeps the last 20).
    static func loadZoneBackups() -> [ZoneBackup] { load(zoneBackupsURL) ?? [] }

    static func appendZoneBackup(_ vw: [String: [[Int]]]) {
        var backups = loadZoneBackups()
        backups.append(ZoneBackup(date: Date(), vw: vw))
        save(Array(backups.suffix(20)), to: zoneBackupsURL)
    }

    static func removeLastZoneBackup() {
        save(Array(loadZoneBackups().dropLast()), to: zoneBackupsURL)
    }

    // The robot token and the Xiaomi login are not stored by the app: vacuumd keeps them (readable only by you)
    // and the app asks it. See RobotServer.settings() and LegacyCredentials for the one-time move from the Keychain.

    private static let hiddenRoomsURL = directory.appendingPathComponent("hidden-rooms.json")

    /// Rooms hidden in this app only (the robot still knows them).
    static func loadHiddenRooms() -> Set<Int> { Set(load(hiddenRoomsURL) as [Int]? ?? []) }
    static func save(hiddenRooms: Set<Int>) { save(hiddenRooms.sorted(), to: hiddenRoomsURL) }

    static func loadRoomNames() -> [Int: String] {
        let stored: [String: String] = load(roomNamesURL) ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in Int(key).map { ($0, value) } })
    }

    static func save(roomNames: [Int: String]) {
        save(Dictionary(uniqueKeysWithValues: roomNames.map { (String($0.key), $0.value) }), to: roomNamesURL)
    }

    private static let roomPreferencesURL = directory.appendingPathComponent("room-preferences.json")

    /// Per-room suction, water and repeat settings, kept in this app only.
    static func loadRoomPreferences() -> [Int: RoomPreference] {
        let stored: [String: RoomPreference] = load(roomPreferencesURL) ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in Int(key).map { ($0, value) } })
    }

    static func save(roomPreferences: [Int: RoomPreference]) {
        save(Dictionary(uniqueKeysWithValues: roomPreferences.map { (String($0.key), $0.value) }), to: roomPreferencesURL)
    }

    private static let furnitureURL = directory.appendingPathComponent("furniture.json")

    /// Furniture pinned to the map in this app only (the robot has no place for it).
    static func loadFurniture() -> [Furniture] { load(furnitureURL) ?? [] }
    static func save(furniture: [Furniture]) { save(furniture, to: furnitureURL) }

    /// Small troubleshooting record (e.g. the last room edit request and the robot's reply).
    static func saveDiagnostic(_ name: String, _ info: [String: String]) {
        save(info, to: directory.appendingPathComponent(name))
    }

    private static func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
