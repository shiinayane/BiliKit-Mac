import Foundation

/// 已认证账户可供界面显示的最小非秘密身份。
public struct AccountIdentity: Sendable, Equatable {
    public let id: Int64
    public let displayName: String
    public let avatarURL: URL?

    public init(id: Int64, displayName: String, avatarURL: URL?) {
        self.id = id
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}
