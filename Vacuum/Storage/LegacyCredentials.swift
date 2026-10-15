import Foundation
import Security

/// Older versions of the app kept the robot token and the Xiaomi login in the Keychain. vacuumd keeps them now,
/// so the app only looks here when vacuumd has nothing yet, once, to move them over (and then deletes them).
/// Everything else never touches the Keychain, so macOS never asks for your password.
enum LegacyCredentials {
    private static let service = "com.lubarino.vacuum"

    static func robot() -> RobotConfig? { read("robot") }
    static func cloud() -> CloudSession? { read("cloud") }

    private static func read<T: Decodable>(_ account: String) -> T? {
        var result: AnyObject?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func remove() {
        for account in ["robot", "cloud"] {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: account]
            SecItemDelete(query as CFDictionary)
        }
    }
}
