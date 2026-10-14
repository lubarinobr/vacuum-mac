import Foundation

// Xiaomi cloud, used only to download map files. Only talks to account.xiaomi.com,
// sts.api.io.mi.com, <server>.api.io.mi.com and the map file URL the cloud returns.
// Request signing follows PiotrMachowski/Xiaomi-cloud-tokens-extractor.

struct CloudSession: Codable {
    var server: String
    var userId: String
    var ssecurity: String
    var serviceToken: String
    var agent: String

    enum CodingKeys: String, CodingKey { case server, userId, ssecurity, serviceToken, agent }

    init(server: String, userId: String, ssecurity: String, serviceToken: String, agent: String) {
        self.server = server
        self.userId = userId
        self.ssecurity = ssecurity
        self.serviceToken = serviceToken
        self.agent = agent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        server = try container.decode(String.self, forKey: .server)
        // The Python test scripts store userId as a number.
        if let number = try? container.decode(Int.self, forKey: .userId) {
            userId = String(number)
        } else {
            userId = try container.decode(String.self, forKey: .userId)
        }
        ssecurity = try container.decode(String.self, forKey: .ssecurity)
        serviceToken = try container.decode(String.self, forKey: .serviceToken)
        agent = try container.decode(String.self, forKey: .agent)
    }
}

enum CloudError: Error, LocalizedError {
    case http(Int)
    case unexpectedReply(String)
    case loginExpired

    var errorDescription: String? {
        switch self {
        case .http(let status): "Xiaomi cloud returned HTTP \(status)."
        case .unexpectedReply(let detail): "Unexpected reply from Xiaomi cloud: \(detail)"
        case .loginExpired: "The Xiaomi login expired. Sign in again to load the map."
        }
    }
}

enum CloudSigning {
    static func signedNonce(ssecurity: String, nonce: String) -> String {
        Crypto.sha256(Data(base64Encoded: ssecurity)! + Data(base64Encoded: nonce)!).base64EncodedString()
    }

    static func signature(method: String, path: String, params: [(String, String)], signedNonce: String) -> String {
        let parts = [method, path] + params.map { "\($0.0)=\($0.1)" } + [signedNonce]
        return Crypto.sha1(Data(parts.joined(separator: "&").utf8)).base64EncodedString()
    }

    static func rc4(_ signedNonce: String, _ data: Data) -> Data {
        Crypto.rc4Drop1024(key: Data(base64Encoded: signedNonce)!, data)
    }

    /// Builds the encrypted, signed form fields for one API call.
    static func fields(path: String, data: String, ssecurity: String, nonce: String) -> [(String, String)] {
        let signedNonce = signedNonce(ssecurity: ssecurity, nonce: nonce)
        var params = [("data", data)]
        params.append(("rc4_hash__", signature(method: "POST", path: path, params: params, signedNonce: signedNonce)))
        params = params.map { ($0.0, rc4(signedNonce, Data($0.1.utf8)).base64EncodedString()) }
        params.append(("signature", signature(method: "POST", path: path, params: params, signedNonce: signedNonce)))
        params.append(("ssecurity", ssecurity))
        params.append(("_nonce", nonce))
        return params
    }

    static func newNonce() -> String {
        var bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
        var minutes = UInt32(Date().timeIntervalSince1970 / 60).bigEndian
        withUnsafeBytes(of: &minutes) { bytes.append(contentsOf: $0) }
        return Data(bytes).base64EncodedString()
    }
}

struct XiaomiCloud {
    let session: CloudSession
    private let http: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15  // give up on a slow server instead of hanging for a minute
        return URLSession(configuration: configuration)
    }()

    private var baseURL: String {
        "https://\(session.server == "cn" ? "" : session.server + ".")api.io.mi.com/app"
    }

    func call(_ endpoint: String, _ payload: [String: Any]) async throws -> [String: Any] {
        let url = URL(string: "\(baseURL)/\(endpoint)")!
        let path = "/" + endpoint
        let nonce = CloudSigning.newNonce()
        let data = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        let fields = CloudSigning.fields(path: path, data: data, ssecurity: session.ssecurity, nonce: nonce)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(fields.map { "\($0.0)=\(formEncode($0.1))" }.joined(separator: "&").utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(session.agent, forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("PROTOCAL-HTTP2", forHTTPHeaderField: "x-xiaomi-protocal-flag-cli")
        request.setValue("ENCRYPT-RC4", forHTTPHeaderField: "MIOT-ENCRYPT-ALGORITHM")
        request.setValue([
            "userId=\(session.userId)", "serviceToken=\(session.serviceToken)",
            "yetAnotherServiceToken=\(session.serviceToken)", "locale=en_GB", "channel=MI_APP_STORE",
        ].joined(separator: "; "), forHTTPHeaderField: "Cookie")

        let (body, response) = try await http.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw CloudError.loginExpired }
        guard status == 200 else { throw CloudError.http(status) }
        guard let encrypted = Data(base64Encoded: String(decoding: body, as: UTF8.self)) else {
            throw CloudError.unexpectedReply(String(decoding: body.prefix(200), as: UTF8.self))
        }
        let signedNonce = CloudSigning.signedNonce(ssecurity: session.ssecurity, nonce: nonce)
        guard let json = try JSONSerialization.jsonObject(with: CloudSigning.rc4(signedNonce, encrypted)) as? [String: Any] else {
            throw CloudError.unexpectedReply("not a JSON object")
        }
        return json
    }

    /// Signed download link for a map file the robot uploaded.
    func mapFileURL(objectName: String) async throws -> URL {
        let reply = try await call("v2/home/get_interim_file_url", ["obj_name": objectName])
        guard let result = reply["result"] as? [String: Any], let link = result["url"] as? String, let url = URL(string: link) else {
            if reply["code"] as? Int == 3 { throw CloudError.loginExpired }
            throw CloudError.unexpectedReply("\(reply)")
        }
        return url
    }

    /// Name of the map file the robot uploaded most recently (property 6.3 history in the cloud).
    /// Used when the robot is busy and doesn't answer a full-map request directly.
    func lastMapObjectName(did: String) async throws -> String? {
        let reply = try await call("user/get_user_device_data", [
            "uid": session.userId, "did": did, "key": "6.3", "type": "prop",
            "limit": 1, "time_start": 0, "time_end": 9_999_999_999,
        ])
        guard let value = (reply["result"] as? [[String: Any]])?.first?["value"] as? String else { return nil }
        if let list = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String], let first = list.first {
            return first
        }
        return value.isEmpty ? nil : value
    }

    func download(_ url: URL) async throws -> String {
        let (body, response) = try await http.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CloudError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return String(decoding: body, as: UTF8.self)
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// Xiaomi's regional servers. Accounts live on one of them, depending on the country chosen at sign-up.
enum XiaomiRegion: String, CaseIterable, Identifiable {
    case de, us, sg, i2, ru, cn, tw, `in`

    var id: String { rawValue }

    var name: String {
        switch self {
        case .de: "Europe"
        case .us: "United States"
        case .sg: "Singapore / Southeast Asia"
        case .i2: "India (i2)"
        case .ru: "Russia"
        case .cn: "China mainland"
        case .tw: "Taiwan"
        case .in: "India"
        }
    }
}

/// A device from the account's device list (same data the token extractor prints).
struct CloudDevice: Identifiable, Hashable {
    let did: String
    let name: String
    let model: String
    let localIP: String
    let token: String
    let region: XiaomiRegion

    var id: String { "\(region.rawValue):\(did)" }
    var isSupported: Bool { model == RobotModel.supported }
    var isVacuum: Bool { model.contains(".vacuum.") }
}

enum RobotModel {
    /// The only model this app supports: Xiaomi Robot Vacuum X20+.
    static let supported = "xiaomi.vacuum.c102gl"
    static let supportedName = "Xiaomi Robot Vacuum X20+"
}

extension XiaomiCloud {
    /// All devices on the account (own homes and homes shared with it) on this session's server.
    func devices(region: XiaomiRegion) async throws -> [CloudDevice] {
        var homes: [(id: Any, owner: Any)] = []
        let homeReply = try await call("v2/homeroom/gethome", [
            "fg": true, "fetch_share": true, "fetch_share_dev": true, "limit": 300, "app_ver": 7,
        ])
        for home in (homeReply["result"] as? [String: Any])?["homelist"] as? [[String: Any]] ?? [] {
            if let id = home["id"] { homes.append((id, Int(session.userId) ?? session.userId)) }
        }
        let sharedReply = try await call("v2/user/get_device_cnt", ["fetch_own": true, "fetch_share": true])
        let shared = ((sharedReply["result"] as? [String: Any])?["share"] as? [String: Any])?["share_family"] as? [[String: Any]] ?? []
        for home in shared {
            if let id = home["home_id"], let owner = home["home_owner"] { homes.append((id, owner)) }
        }

        var devices: [CloudDevice] = []
        for home in homes {
            let reply = try await call("v2/home/home_device_list", [
                "home_owner": home.owner, "home_id": home.id, "limit": 200,
                "get_split_device": true, "support_smart_home": true,
            ])
            for info in (reply["result"] as? [String: Any])?["device_info"] as? [[String: Any]] ?? [] {
                guard let did = info["did"].map({ "\($0)" }) else { continue }
                devices.append(CloudDevice(
                    did: did,
                    name: info["name"] as? String ?? "Device",
                    model: info["model"] as? String ?? "",
                    localIP: info["localip"] as? String ?? "",
                    token: info["token"] as? String ?? "",
                    region: region))
            }
        }
        return devices
    }
}

/// Sign-in on Xiaomi's website (or by QR code): no password is typed in this app.
struct XiaomiQRLogin {
    struct Start {
        let qrImageURL: URL
        /// Xiaomi's own sign-in page for this session; signing in there confirms it (no Xiaomi app needed).
        let webLoginURL: URL?
        let pollURL: URL
        let timeout: TimeInterval
    }

    private let http: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 70  // long enough for the 60 s confirmation wait
        return URLSession(configuration: configuration)
    }()
    let agent: String = {
        let id = String((0..<13).map { _ in Character(UnicodeScalar(UInt8.random(in: 65...69))) })
        let text = String((0..<18).map { _ in Character(UnicodeScalar(UInt8.random(in: 97...122))) })
        return "\(text)-\(id) APP/com.xiaomi.mihome APPV/10.5.201"
    }()

    func start() async throws -> Start {
        // Encoded like Python's urlencode: "qs" is already percent-encoded and gets encoded again.
        let query: [(String, String)] = [
            ("_qrsize", "480"),
            ("qs", "%3Fsid%3Dxiaomiio%26_json%3Dtrue"),
            ("callback", "https://sts.api.io.mi.com/sts"),
            ("_hasLogo", "false"),
            ("sid", "xiaomiio"),
            ("serviceParam", ""),
            ("_locale", "en_GB"),
            ("_dc", String(Int(Date().timeIntervalSince1970 * 1000))),
        ]
        let queryString = query.map { "\($0.0)=\(Self.urlEncode($0.1))" }.joined(separator: "&")
        let url = URL(string: "https://account.xiaomi.com/longPolling/loginUrl?\(queryString)")!
        LoginDiagnostics.reset()
        let json = try await getJSON(url)
        LoginDiagnostics.log("loginUrl: keys \(json.keys.sorted()), timeout \(json["timeout"] ?? "none")")
        guard let qr = (json["qr"] as? String).flatMap(URL.init), let lp = (json["lp"] as? String).flatMap(URL.init) else {
            throw CloudError.unexpectedReply("\(json)")
        }
        return Start(qrImageURL: qr, webLoginURL: (json["loginUrl"] as? String).flatMap(URL.init),
                     pollURL: lp, timeout: json["timeout"] as? TimeInterval ?? 300)
    }

    func qrImage(_ start: Start) async throws -> Data {
        try await http.data(from: start.qrImageURL).0
    }

    /// Waits until the QR code is scanned and confirmed in the Xiaomi Home app.
    func waitForConfirmation(_ start: Start, server: String = "de") async throws -> CloudSession {
        let deadline = Date().addingTimeInterval(start.timeout)
        var attempts = 0
        var refusals = 0
        while Date() < deadline {
            try Task.checkCancellation()
            attempts += 1
            // Xiaomi answers the waiting connection once, when sign-in is confirmed. Keep it open long
            // enough that the answer can't arrive just as we hang up (that loses it for good).
            var request = URLRequest(url: start.pollURL)
            request.timeoutInterval = 60
            let body: Data
            do {
                let (data, response) = try await http.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                LoginDiagnostics.log("poll \(attempts): HTTP \(status), \(data.count) bytes")
                guard status == 200 else {
                    refusals += 1
                    LoginDiagnostics.log("  reply: \(String(decoding: data.prefix(200), as: UTF8.self).replacingOccurrences(of: "\n", with: " "))")
                    if refusals >= 3 { throw CloudError.unexpectedReply("Xiaomi refused the sign-in (HTTP \(status)). It may have expired: try again.") }
                    try await Task.sleep(for: .seconds(2))  // never hammer Xiaomi's servers
                    continue
                }
                body = data
            } catch let error as CloudError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                LoginDiagnostics.log("poll \(attempts): \((error as NSError).code == NSURLErrorTimedOut ? "waiting (timeout)" : error.localizedDescription)")
                try await Task.sleep(for: .seconds(1))
                continue
            }
            let json = try Self.parse(body)
            LoginDiagnostics.log("confirmed: keys \(json.keys.sorted())")
            guard let ssecurity = json["ssecurity"] as? String, let location = (json["location"] as? String).flatMap(URL.init) else {
                throw CloudError.unexpectedReply("\(json)")
            }
            let userId = (json["userId"] as? Int).map(String.init) ?? json["userId"] as? String ?? ""
            let (_, tokenResponse) = try await http.data(from: location)
            guard let httpResponse = tokenResponse as? HTTPURLResponse,
                  let headers = httpResponse.allHeaderFields as? [String: String],
                  let token = HTTPCookie.cookies(withResponseHeaderFields: headers, for: location)
                      .first(where: { $0.name == "serviceToken" })?.value else {
                LoginDiagnostics.log("no service token in the reply")
                throw CloudError.unexpectedReply("no service token")
            }
            LoginDiagnostics.log("service token received")
            return CloudSession(server: server, userId: userId, ssecurity: ssecurity, serviceToken: token, agent: agent)
        }
        throw CloudError.unexpectedReply("QR code expired")
    }

    static func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func getJSON(_ url: URL) async throws -> [String: Any] {
        try Self.parse(try await http.data(from: url).0)
    }

    private static func parse(_ body: Data) throws -> [String: Any] {
        let text = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "&&&START&&&", with: "")
        guard let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CloudError.unexpectedReply(String(text.prefix(200)))
        }
        return json
    }
}

/// Records each step of the QR sign-in in Application Support/Vacuum/last-login.log (no secrets).
enum LoginDiagnostics {
    private static let url = AppStore.directory.appendingPathComponent("last-login.log")

    static func reset() { try? Data().write(to: url) }

    static func log(_ line: String) {
        let entry = "\(Date().formatted(date: .omitted, time: .standard))  \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: url)
        }
    }
}
