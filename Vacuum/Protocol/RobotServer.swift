import Foundation

/// The vacuumd server (Rust) owns the one connection to the robot. The app talks to it over loopback HTTP,
/// the same server AI agents use through MCP, so the two never fight over the robot.
final class RobotServer: @unchecked Sendable {
    static let shared = RobotServer()

    let port: Int
    private let directory: URL
    private let http: URLSession

    init(port: Int? = nil, directory: URL = AppStore.directory, session: URLSession? = nil) {
        self.port = port ?? ProcessInfo.processInfo.environment["VACUUMD_PORT"].flatMap(Int.init) ?? 47231
        self.directory = directory
        if let session {
            http = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            http = URLSession(configuration: configuration)
        }
    }

    private var base: String { "http://127.0.0.1:\(port)" }

    /// The shared secret in the data folder; created here if the server hasn't made it yet.
    func token() -> String? {
        let url = directory.appendingPathComponent("daemon-token")
        if let text = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 32 {
            return text
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = Data(bytes).hex
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? Data(token.utf8).write(to: url, options: .atomic)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }

    func isRunning() async -> Bool {
        guard let url = URL(string: base + "/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await http.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// The robot's raw property values, as last read by the server (never older than a few seconds).
    struct Properties {
        var online: Bool
        var error: String?
        var values: [PropertyID: Any]
    }

    func properties() async throws -> Properties {
        let (status, json) = try await request("GET", "/v1/properties")
        guard status == 200 else { throw MiIOError.server(Self.message(json, status)) }
        var values: [PropertyID: Any] = [:]
        for (key, value) in json["values"] as? [String: Any] ?? [:] {
            let parts = key.split(separator: ".").compactMap { Int($0) }
            if parts.count == 2 { values[PropertyID(siid: parts[0], piid: parts[1])] = value }
        }
        return Properties(online: json["online"] as? Bool ?? false, error: json["error"] as? String, values: values)
    }

    /// The robot and Xiaomi sign-in vacuumd holds (nil for what isn't set up yet). An older vacuumd that doesn't
    /// know this endpoint (404) counts as "nothing saved".
    struct SavedSettings {
        var robot: RobotConfig?
        var cloud: CloudSession?
    }

    func settings() async throws -> SavedSettings {
        let (status, json) = try await request("GET", "/v1/config")
        if status == 404 { return SavedSettings() }
        guard status == 200 else { throw MiIOError.server(Self.message(json, status)) }
        func decode<T: Decodable>(_ key: String) -> T? {
            guard let value = json[key], !(value is NSNull), let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        return SavedSettings(robot: decode("robot"), cloud: decode("cloud"))
    }

    /// Hands the robot and Xiaomi settings to the server (it keeps them for when the app is closed).
    func configure(robot: RobotConfig?, cloud: CloudSession?) async throws {
        var body: [String: Any] = [:]
        if let robot { body["robot"] = ["ip": robot.ip, "token": robot.token, "did": robot.did] }
        if let cloud, let data = try? JSONEncoder().encode(cloud), let json = try? JSONSerialization.jsonObject(with: data) { body["cloud"] = json }
        let (status, json) = try await request("POST", "/v1/config", body: body)
        guard status == 200 else { throw MiIOError.server(Self.message(json, status)) }
    }

    /// One raw miIO request, sent by the server.
    ///
    /// The server only forwards the commands listed in rust/src/policy.rs (what this app sends). If you add a new
    /// robot command to the app, add it there too (and to its test), or the server will refuse it with a 403.
    /// `drive` uses a separate connection so steering never waits.
    func miio(_ method: String, _ params: Any, timeout: TimeInterval, retry: Bool, drive: Bool) async throws -> Any {
        var body: [String: Any] = ["method": method, "params": params, "timeout_ms": Int(timeout * 1000), "retry": retry]
        if drive { body["channel"] = "drive" }
        // The server may retry once (and handshake), so allow for that before giving up on it.
        let (status, json) = try await request("POST", "/v1/miio", body: body, timeout: max(timeout * 2 + 12, 15))
        switch status {
        case 200: return json["result"] ?? NSNull()
        case 502:
            let text = json["error"] as? String ?? ""
            switch json["kind"] as? String {
            case "timeout": throw MiIOError.timeout
            case "device": throw MiIOError.device(code: json["code"] as? Int ?? -1, message: text)
            case "invalid": throw MiIOError.invalidPacket
            default: throw MiIOError.socket(text)
            }
        default: throw MiIOError.server(Self.message(json, status))
        }
    }

    // MARK: - HTTP

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 30) async throws -> (Int, [String: Any]) {
        guard let token = token(), let url = URL(string: base + path) else { throw MiIOError.server("No access token.") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await http.data(for: request)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
        } catch let error as URLError where [.cannotConnectToHost, .networkConnectionLost, .timedOut, .cannotFindHost].contains(error.code) {
            throw MiIOError.server("The Vacuum background service isn't running.")
        }
    }

    private static func message(_ json: [String: Any], _ status: Int) -> String {
        if status == 401 { return "The background service didn't accept this app's access token." }
        return json["error"] as? String ?? "The background service answered with HTTP \(status)."
    }
}

/// Same shape as the old direct client, so the controller's map, zone and driving code didn't have to change.
final class RemoteMiIOClient: @unchecked Sendable {
    private let server: RobotServer
    private let drive: Bool

    init(server: RobotServer = .shared, drive: Bool = false) {
        self.server = server
        self.drive = drive
    }

    func send(_ method: String, _ params: Any, timeout: TimeInterval = 5, retry: Bool = true) async throws -> Any {
        try await server.miio(method, params, timeout: timeout, retry: retry, drive: drive)
    }
}
