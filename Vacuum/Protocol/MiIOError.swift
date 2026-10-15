import Foundation

// The robot is reached through the vacuumd server (see RobotServer.swift), which speaks the local miIO
// protocol. This file keeps the error type the rest of the app uses and a few byte helpers.

enum MiIOError: Error, LocalizedError {
    case timeout
    case invalidPacket
    case socket(String)
    case device(code: Int, message: String)
    /// The Vacuum background service (vacuumd) couldn't be reached or refused the request.
    case server(String)

    var errorDescription: String? {
        switch self {
        case .timeout: "The robot isn't answering. It may be asleep or off Wi-Fi: press a button on it or lift it off the dock, then try again."
        case .invalidPacket: "The robot sent an unexpected reply."
        case .socket(let message): message.hasPrefix("Can't reach the robot") ? message : "Network error: \(message)"
        case .device(let code, let message): "The robot refused the command (\(code)): \(message)"
        case .server(let message): message
        }
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
