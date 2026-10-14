import CommonCrypto
import Compression
import CryptoKit
import Foundation

enum CryptoError: Error {
    case aesFailed(Int32)
    case decompressFailed
}

enum Crypto {
    static func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    static func sha1(_ data: Data) -> Data {
        Data(Insecure.SHA1.hash(data: data))
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func aesCBC(_ operation: CCOperation, _ data: Data, key: Data, iv: Data, padding: Bool) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var written = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), padding ? CCOptions(kCCOptionPKCS7Padding) : 0,
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, data.count, out.baseAddress, outputCapacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.aesFailed(status) }
        return output.prefix(written)
    }

    /// RC4 that drops the first 1024 keystream bytes (Xiaomi cloud's "RC4-drop1024").
    static func rc4Drop1024(key: Data, _ data: Data) -> Data {
        var s = Array(0...255).map(UInt8.init)
        let k = [UInt8](key)
        var j = 0
        for i in 0..<256 {
            j = (j + Int(s[i]) + Int(k[i % k.count])) & 0xFF
            s.swapAt(i, j)
        }
        var i = 0
        j = 0
        func next() -> UInt8 {
            i = (i + 1) & 0xFF
            j = (j + Int(s[i])) & 0xFF
            s.swapAt(i, j)
            return s[(Int(s[i]) + Int(s[j])) & 0xFF]
        }
        for _ in 0..<1024 { _ = next() }
        return Data(data.map { $0 ^ next() })
    }

    /// Inflates a zlib stream (2-byte header + deflate). Trailing bytes after the stream are ignored.
    static func zlibDecompress(_ data: Data) throws -> Data {
        guard data.count > 2 else { throw CryptoError.decompressFailed }
        let deflate = data.dropFirst(2)
        var capacity = max(data.count * 8, 64 * 1024)
        while capacity <= 64 * 1024 * 1024 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { out in
                deflate.withUnsafeBytes { input in
                    compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              input.bindMemory(to: UInt8.self).baseAddress!, deflate.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            if written == 0 { throw CryptoError.decompressFailed }
            if written < capacity { return output.prefix(written) }
            capacity *= 4
        }
        throw CryptoError.decompressFailed
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
