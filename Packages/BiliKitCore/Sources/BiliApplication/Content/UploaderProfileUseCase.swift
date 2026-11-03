import BiliModels
import Foundation

/// 取得 UP 主的公开名片，并规范化其中可选的名字与签名。
public struct UploaderProfileUseCase: Sendable {
    private let repository: any UploaderProfileRepository

    public init(repository: any UploaderProfileRepository) {
        self.repository = repository
    }

    public func profile(for ownerID: Int64) async throws -> UploaderProfile {
        guard ownerID > 0 else {
            throw ContentApplicationError.invalidRequest
        }
        let profile = try await repository.uploaderProfile(for: ownerID)
        try Task.checkCancellation()
        return UploaderProfile(
            name: Self.singleLine(profile.name),
            avatarURL: profile.avatarURL,
            signature: Self.singleLine(profile.signature),
            isVIP: profile.isVIP,
            followerCount: profile.followerCount,
            videoCount: profile.videoCount
        )
    }

    /// 把连续空白折叠为单个空格，结果为空时视为缺省；UP 主名称与签名展示共用这一规则。
    package static func singleLine(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized =
            value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}
