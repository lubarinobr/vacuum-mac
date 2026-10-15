import Foundation

struct RobotConfig: Codable, Equatable {
    var ip: String
    var token: String  // 32 hex characters
    var did: String
}
