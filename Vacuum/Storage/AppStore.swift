import Foundation
import Security

struct RobotConfig: Codable, Equatable {
    var ip: String
    var token: String  // 32 hex characters
    var did: String
}

/// Files in ~/Library/Application Support/Vacuum, readable only by you (permissions 600).
/// Nothing here leaves this Mac. (Moving the token into the Keychain is a good next step
/// once the app is signed with an Apple developer identity.)
enum AppStore {
    static let directory: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vacuum", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let robotURL = directory.appendingPathComponent("robot.json")
    private static let cloudURL = directory.appendingPathComponent("cloud.json")
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

    // The robot token and Xiaomi login are secrets. Release builds keep them in the Keychain;
    // development builds use the private files, because every rebuild has a new signature and
    // the Keychain would ask for your password each time.
    static func loadRobot() -> RobotConfig? { loadSecret("robot", fileURL: robotURL) }
    static func save(_ robot: RobotConfig) { saveSecret(robot, "robot", fileURL: robotURL) }

    static func loadCloud() -> CloudSession? { loadSecret("cloud", fileURL: cloudURL) }
    static func save(_ cloud: CloudSession) { saveSecret(cloud, "cloud", fileURL: cloudURL) }

    private static func loadSecret<T: Decodable>(_ account: String, fileURL: URL) -> T? {
        #if DEBUG
        return load(fileURL)
        #else
        if let data = Keychain.read(account), let value = try? JSONDecoder().decode(T.self, from: data) { return value }
        // One-time move from the files an older build wrote.
        guard let data = try? Data(contentsOf: fileURL), let value = try? JSONDecoder().decode(T.self, from: data) else { return nil }
        if Keychain.write(account, data) { try? FileManager.default.removeItem(at: fileURL) }
        return value
        #endif
    }

    private static func saveSecret<T: Encodable>(_ value: T, _ account: String, fileURL: URL) {
        #if DEBUG
        save(value, to: fileURL)
        #else
        guard let data = try? JSONEncoder().encode(value) else { return }
        if Keychain.write(account, data) { try? FileManager.default.removeItem(at: fileURL) } else { save(value, to: fileURL) }
        #endif
    }

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

/// Minimal Keychain wrapper (generic passwords for this app).
enum Keychain {
    private static let service = "com.lubarino.vacuum"

    static func read(_ account: String) -> Data? {
        var result: AnyObject?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }

    @discardableResult
    static func write(_ account: String, _ data: Data) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}
