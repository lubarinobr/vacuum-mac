import Foundation
import Testing
@testable import Vacuum

/// Stands in for the vacuumd server: records each request and answers from a closure.
final class StubServer: URLProtocol, @unchecked Sendable {
    struct Seen {
        var method: String
        var path: String
        var authorization: String?
        var body: [String: Any]
    }

    nonisolated(unsafe) static var handler: ((Seen) throws -> (Int, [String: Any]))?
    nonisolated(unsafe) static var seen: [Seen] = []
    private static let lock = NSLock()

    static func install(_ handler: @escaping (Seen) throws -> (Int, [String: Any])) -> URLSession {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        seen = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return URLSession(configuration: configuration)
    }

    static func requests(_ path: String? = nil) -> [Seen] {
        lock.lock(); defer { lock.unlock() }
        return seen.filter { path == nil || $0.path == path }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { /* nothing to cancel: the stub answers immediately */ }

    override func startLoading() {
        var body: [String: Any] = [:]
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        } else if let data = request.httpBody {
            body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        let seen = Seen(method: request.httpMethod ?? "", path: request.url?.path ?? "",
                        authorization: request.value(forHTTPHeaderField: "Authorization"), body: body)
        Self.lock.lock()
        Self.seen.append(seen)
        let handler = Self.handler
        Self.lock.unlock()
        do {
            let (status, json) = try handler?(seen) ?? (404, [:])
            let data = try JSONSerialization.data(withJSONObject: json)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vacuum-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let properties: [String: Any] = [
    "online": true,
    "values": ["2.1": 13, "3.1": 87, "2.3": 1, "4.5": 2, "4.23": 2, "5.2": "22:00"],
]

@Suite(.serialized) struct RobotServerTests {
    @Test func createsASecretTokenOnlyYouCanReadAndKeepsIt() throws {
        let directory = temporaryDirectory()
        let server = RobotServer(directory: directory, session: StubServer.install { _ in (200, [:]) })
        let token = try #require(server.token())
        #expect(token.count == 64)
        #expect(server.token() == token)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("daemon-token").path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func usesTheTokenTheServerAlreadyMade() throws {
        let directory = temporaryDirectory()
        let existing = String(repeating: "ab", count: 32)
        try existing.write(to: directory.appendingPathComponent("daemon-token"), atomically: true, encoding: .utf8)
        let server = RobotServer(directory: directory, session: StubServer.install { _ in (200, [:]) })
        #expect(server.token() == existing)
    }

    @Test func knowsWhetherTheServerIsRunning() async {
        let up = RobotServer(directory: temporaryDirectory(), session: StubServer.install { _ in (200, ["ok": true]) })
        #expect(await up.isRunning())
        let down = RobotServer(directory: temporaryDirectory(), session: StubServer.install { _ in throw URLError(.cannotConnectToHost) })
        #expect(await down.isRunning() == false)
    }

    @Test func readsPropertiesAndSendsTheToken() async throws {
        let server = RobotServer(directory: temporaryDirectory(), session: StubServer.install { _ in (200, properties) })
        let reading = try await server.properties()
        #expect(reading.online)
        #expect(reading.values[Spec.status] as? Int == 13)
        #expect(reading.values[Spec.battery] as? Int == 87)
        #expect(reading.values[Spec.dndStart] as? String == "22:00")
        let request = try #require(StubServer.requests("/v1/properties").first)
        #expect(request.authorization == "Bearer \(try #require(server.token()))")
    }

    @Test func sendsRawRequestsWithTheRightOptions() async throws {
        let server = RobotServer(directory: temporaryDirectory(), session: StubServer.install { _ in (200, ["result": [["code": 0]]]) })
        let result = try await server.miio("set_properties", [["siid": 4]], timeout: 0.3, retry: false, drive: true)
        #expect((result as? [[String: Any]])?.first?["code"] as? Int == 0)
        let body = try #require(StubServer.requests("/v1/miio").first).body
        #expect(body["method"] as? String == "set_properties")
        #expect(body["timeout_ms"] as? Int == 300)
        #expect(body["retry"] as? Bool == false)
        #expect(body["channel"] as? String == "drive")

        _ = try await server.miio("get_properties", [], timeout: 5, retry: true, drive: false)
        #expect(StubServer.requests("/v1/miio").last?.body["channel"] == nil, "the normal channel is the default")
    }

    @Test func mapsEachFailureKind() async throws {
        func error(_ status: Int, _ json: [String: Any]) async throws -> MiIOError {
            let server = RobotServer(directory: temporaryDirectory(), session: StubServer.install { _ in (status, json) })
            do { _ = try await server.miio("x", [], timeout: 1, retry: false, drive: false) } catch let e as MiIOError { return e }
            throw URLError(.unknown)
        }
        guard case .timeout = try await error(502, ["kind": "timeout", "error": "t"]) else { Issue.record("timeout"); return }
        guard case .device(let code, _) = try await error(502, ["kind": "device", "code": -9999, "error": "no"]) else { Issue.record("device"); return }
        #expect(code == -9999)
        guard case .socket = try await error(502, ["kind": "socket", "error": "down"]) else { Issue.record("socket"); return }
        guard case .invalidPacket = try await error(502, ["kind": "invalid", "error": "x"]) else { Issue.record("invalid"); return }
        guard case .server(let message) = try await error(401, [:]) else { Issue.record("401"); return }
        #expect(message.contains("access token"))
        guard case .server(let text) = try await error(400, ["error": "No robot is set up yet."]) else { Issue.record("400"); return }
        #expect(text == "No robot is set up yet.")
    }

    @Test func aMissingServerIsExplained() async {
        let server = RobotServer(directory: temporaryDirectory(), session: StubServer.install { _ in throw URLError(.cannotConnectToHost) })
        do {
            _ = try await server.properties()
            Issue.record("should have failed")
        } catch {
            #expect(error.localizedDescription.contains("background service isn't running"))
        }
    }

    @Test func handsOverTheSettingsInTheShapeTheServerReads() async throws {
        let server = RobotServer(directory: temporaryDirectory(), session: StubServer.install { _ in (200, ["ok": true]) })
        let cloud = CloudSession(server: "de", userId: "42", ssecurity: "s", serviceToken: "t", agent: "a")
        try await server.configure(robot: RobotConfig(ip: "10.0.0.5", token: String(repeating: "ab", count: 16), did: "99"), cloud: cloud)
        let body = try #require(StubServer.requests("/v1/config").first).body
        #expect((body["robot"] as? [String: Any])?["ip"] as? String == "10.0.0.5")
        #expect((body["robot"] as? [String: Any])?["did"] as? String == "99")
        let sent = try #require(body["cloud"] as? [String: Any])
        #expect(sent["serviceToken"] as? String == "t")
        #expect(sent["userId"] as? String == "42")
    }
}

@MainActor
@Suite(.serialized) struct RobotControllerServerTests {
    private let robot = RobotConfig(ip: "10.0.0.5", token: String(repeating: "ab", count: 16), did: "99")

    private func controller(_ session: URLSession, startServer: @escaping (RobotServer) async -> String? = { _ in nil }) -> RobotController {
        RobotController(server: RobotServer(directory: temporaryDirectory(), session: session), loadSavedSettings: false, startServer: startServer)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func showsWhatTheServerReports() async {
        let robotController = controller(StubServer.install { request in
            request.path == "/v1/properties" ? (200, properties) : (200, ["ok": true])
        })
        robotController.configure(robot: robot, cloud: nil, persist: false)
        await waitUntil { robotController.isConnected }
        #expect(robotController.isConnected)
        #expect(robotController.statusText == "Fully charged")
        #expect(robotController.int(Spec.battery) == 87)
        #expect(robotController.lastError == nil)
        #expect(StubServer.requests("/v1/config").count >= 1, "the server is given the settings")
    }

    @Test func showsWhenTheRobotIsOffline() async {
        let robotController = controller(StubServer.install { request in
            request.path == "/v1/properties" ? (200, ["online": false, "error": "The robot didn't answer.", "values": [String: Any]()]) : (200, ["ok": true])
        })
        robotController.configure(robot: robot, cloud: nil, persist: false)
        await waitUntil { robotController.lastError != nil }
        #expect(robotController.isConnected == false)
        #expect(robotController.lastError == "The robot didn't answer.")
    }

    @Test func explainsWhenTheServerCannotBeStarted() async {
        let robotController = controller(StubServer.install { _ in throw URLError(.cannotConnectToHost) },
                                         startServer: { _ in "The Vacuum background service isn't installed." })
        robotController.configure(robot: robot, cloud: nil, persist: false)
        await waitUntil { robotController.lastError != nil }
        #expect(robotController.isConnected == false)
        #expect(robotController.lastError == "The Vacuum background service isn't installed.")
        #expect(StubServer.requests("/v1/properties").isEmpty, "nothing is asked of a server that isn't there")
    }

    @Test func recoversWhenTheServerComesBack() async {
        nonisolated(unsafe) var up = false
        let robotController = controller(StubServer.install { request in
            if !up { throw URLError(.cannotConnectToHost) }
            return request.path == "/v1/properties" ? (200, properties) : (200, ["ok": true])
        }, startServer: { _ in up ? nil : "down" })
        robotController.configure(robot: robot, cloud: nil, persist: false)
        await waitUntil { robotController.lastError == "down" }
        up = true
        await robotController.refresh()
        #expect(robotController.isConnected)
        #expect(robotController.lastError == nil)
    }

    @Test func commandsGoThroughTheServerAsActions() async {
        let robotController = controller(StubServer.install { request in
            switch request.path {
            case "/v1/properties": (200, properties)
            case "/v1/miio": (200, ["result": ["code": 0]])
            default: (200, ["ok": true])
            }
        })
        robotController.configure(robot: robot, cloud: nil, persist: false)
        await waitUntil { robotController.isConnected }
        await robotController.goHome()
        let actions = StubServer.requests("/v1/miio").map(\.body).filter { $0["method"] as? String == "action" }
        let params = actions.last?["params"] as? [String: Any]
        #expect(params?["siid"] as? Int == 3)
        #expect(params?["aiid"] as? Int == 1)
        #expect(robotController.lastError == nil)
    }

    @Test func aRefusedCommandIsShown() async {
        let robotController = controller(StubServer.install { request in
            switch request.path {
            case "/v1/properties": (200, properties)
            case "/v1/miio": (502, ["kind": "device", "code": -9999, "error": "refused"])
            default: (200, ["ok": true])
            }
        })
        robotController.configure(robot: robot, cloud: nil, persist: false)
        await waitUntil { robotController.isConnected }
        await robotController.goHome()
        #expect(robotController.lastError?.contains("refused") == true)
    }

    @Test func drivingUsesItsOwnChannelAndToleratesLostReplies() async {
        let robotController = controller(StubServer.install { request in
            switch request.path {
            case "/v1/properties": (200, properties)
            case "/v1/miio": (502, ["kind": "timeout", "error": "t"])
            default: (200, ["ok": true])
            }
        })
        robotController.configure(robot: robot, cloud: nil, persist: false)
        await waitUntil { robotController.isConnected }
        let delivered = await robotController.drive(rotation: 10, velocity: 150)
        #expect(delivered == false)
        #expect(robotController.lastError == nil, "a single lost steering reply is normal")
        let body = StubServer.requests("/v1/miio").map(\.body).last { $0["channel"] as? String == "drive" }
        #expect(body != nil)
        #expect(body?["retry"] as? Bool == false)
        #expect(body?["timeout_ms"] as? Int == 300)
        let params = body?["params"] as? [[String: Any]]
        let payload = (params?.first?["value"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        #expect(payload?["spdv"] as? Int == 150)
        #expect(payload?["spdw"] as? Int == 10)
        #expect(payload?["audio"] as? String == "true")
    }
}
