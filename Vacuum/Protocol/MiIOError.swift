import CommonCrypto
import Foundation

// Local miIO protocol (UDP port 54321), as implemented by python-miio.
//
// Packet = 32-byte header + AES-128-CBC(JSON + "\0")
//   0  magic 0x2131      2  total length      4  unknown (0)
//   8  device id        12  stamp (seconds)   16  MD5(header[0..<16] + token + payload)
// key = MD5(token), iv = MD5(key + token)

enum MiIOError: Error, LocalizedError {
    case timeout
    case invalidPacket
    case socket(String)
    case device(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .timeout: "The robot didn't answer. Is it on and connected to Wi-Fi?"
        case .invalidPacket: "The robot sent an unexpected reply."
        case .socket(let message): "Network error: \(message)"
        case .device(let code, let message): "The robot refused the command (\(code)): \(message)"
        }
    }
}

struct MiIOPacket {
    static let hello = Data(hex: "21310020" + String(repeating: "ff", count: 28))!

    let token: Data
    var key: Data { Crypto.md5(token) }
    var iv: Data { Crypto.md5(key + token) }

    func encode(_ plaintext: Data, deviceID: UInt32, stamp: UInt32) throws -> Data {
        let encrypted = try Crypto.aesCBC(CCOperation(kCCEncrypt), plaintext, key: key, iv: iv, padding: true)
        var header = Data()
        header.appendBigEndian(UInt16(0x2131))
        header.appendBigEndian(UInt16(32 + encrypted.count))
        header.appendBigEndian(UInt32(0))
        header.appendBigEndian(deviceID)
        header.appendBigEndian(stamp)
        let checksum = Crypto.md5(header + token + encrypted)
        return header + checksum + encrypted
    }

    struct Decoded {
        let deviceID: UInt32
        let stamp: UInt32
        let payload: Data
    }

    func decode(_ packet: Data) throws -> Decoded {
        guard packet.count >= 32, packet.readBigEndianUInt16(at: 0) == 0x2131 else { throw MiIOError.invalidPacket }
        let deviceID = packet.readBigEndianUInt32(at: 8)
        let stamp = packet.readBigEndianUInt32(at: 12)
        guard packet.count > 32 else { return Decoded(deviceID: deviceID, stamp: stamp, payload: Data()) }
        var plaintext = try Crypto.aesCBC(CCOperation(kCCDecrypt), packet.dropFirst(32), key: key, iv: iv, padding: true)
        while plaintext.last == 0 { plaintext.removeLast() }
        return Decoded(deviceID: deviceID, stamp: stamp, payload: plaintext)
    }
}

/// Talks to one robot. All socket work runs on a private serial queue, one request at a time.
final class MiIOClient: @unchecked Sendable {
    private let ip: String
    private let packet: MiIOPacket
    private let queue = DispatchQueue(label: "miio.client")
    private var socketFD: Int32 = -1
    private var deviceID: UInt32?
    private var deviceStamp: UInt32 = 0
    private var stampReceivedAt = Date()
    private var nextID = Int.random(in: 1...10_000)

    init(ip: String, token: Data) {
        self.ip = ip
        self.packet = MiIOPacket(token: token)
    }

    deinit {
        if socketFD >= 0 { close(socketFD) }
    }

    /// Sends {"id", "method", "params"} and returns the reply's "result".
    /// `timeout` is how long to wait for the reply; without `retry` a lost reply just throws `.timeout`.
    func send(_ method: String, _ params: Any, timeout: TimeInterval = 5, retry: Bool = true) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: retry ? try self.sendWithRetry(method, params)
                                                         : try self.sendOnce(method, params, timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Blocking internals (only called on `queue`)

    private func sendWithRetry(_ method: String, _ params: Any) throws -> Any {
        do {
            return try sendOnce(method, params)
        } catch MiIOError.timeout {
            deviceID = nil  // re-handshake and try once more
            return try sendOnce(method, params)
        } catch MiIOError.socket {
            closeSocket()  // a failed socket stays broken; start over with a fresh one
            return try sendOnce(method, params)
        }
    }

    private func closeSocket() {
        if socketFD >= 0 { close(socketFD) }
        socketFD = -1
        deviceID = nil
    }

    private func sendOnce(_ method: String, _ params: Any, timeout: TimeInterval = 5) throws -> Any {
        try openSocketIfNeeded()
        if deviceID == nil { try handshake() }

        nextID += 1
        let id = nextID
        let body = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        let stamp = deviceStamp &+ UInt32(max(0, Date().timeIntervalSince(stampReceivedAt))) &+ 1
        try write(try packet.encode(body + Data([0]), deviceID: deviceID!, stamp: stamp))

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let decoded = try packet.decode(try read(until: deadline))
            updateStamp(decoded.stamp)
            guard let json = try? JSONSerialization.jsonObject(with: decoded.payload) as? [String: Any],
                  json["id"] as? Int == id else { continue }  // stale reply from an earlier request
            if let error = json["error"] as? [String: Any] {
                throw MiIOError.device(code: error["code"] as? Int ?? -1, message: error["message"] as? String ?? "")
            }
            return json["result"] ?? NSNull()
        }
        throw MiIOError.timeout
    }

    private func handshake() throws {
        try write(MiIOPacket.hello)
        let decoded = try packet.decode(try read(until: Date().addingTimeInterval(5)))
        deviceID = decoded.deviceID
        updateStamp(decoded.stamp)
    }

    private func updateStamp(_ stamp: UInt32) {
        deviceStamp = stamp
        stampReceivedAt = Date()
    }

    private func openSocketIfNeeded() throws {
        guard socketFD < 0 else { return }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw MiIOError.socket(String(cString: strerror(errno))) }
        var noSigPipe: Int32 = 1  // report errors instead of killing the app with SIGPIPE
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(54321).bigEndian
        guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else {
            close(fd)
            throw MiIOError.socket("Invalid IP address \(ip)")
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            close(fd)
            throw MiIOError.socket(String(cString: strerror(errno)))
        }
        socketFD = fd
    }

    private func write(_ data: Data) throws {
        drainPending()
        let sent = data.withUnsafeBytes { Darwin.send(socketFD, $0.baseAddress, data.count, 0) }
        guard sent == data.count else {
            let message = String(cString: strerror(errno))
            closeSocket()
            throw MiIOError.socket(message)
        }
    }

    private func read(until deadline: Date) throws -> Data {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw MiIOError.timeout }
        var timeout = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining - floor(remaining)) * 1_000_000))
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = recv(socketFD, &buffer, buffer.count, 0)
        if count < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { throw MiIOError.timeout }
            let message = String(cString: strerror(errno))
            closeSocket()
            throw MiIOError.socket(message)
        }
        return Data(buffer.prefix(count))
    }

    private func drainPending() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while recv(socketFD, &buffer, buffer.count, MSG_DONTWAIT) > 0 {}
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func readBigEndianUInt16(at offset: Int) -> UInt16 {
        let start = startIndex + offset
        return UInt16(self[start]) << 8 | UInt16(self[start + 1])
    }

    func readBigEndianUInt32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(self[start + $1]) }
    }

    func readLittleEndian<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        let start = startIndex + offset
        return (0..<MemoryLayout<T>.size).reversed().reduce(T.zero) { $0 << 8 | T(truncatingIfNeeded: self[start + $1]) }
    }
}
