import BiliModels
import Foundation

public enum VideoUploaderSignatureState: Equatable, Sendable {
    case loading
    case loaded(String?)
}

public enum VideoUploaderSignatureContent: Equatable, Sendable {
    case loading
    case hidden
    case text(String)
}

/// 把 UP 主字段规范化为平台 renderer 可直接消费的稳定展示值。
public struct VideoUploaderHeaderContent: Equatable, Sendable {
    public let name: String
    public let avatarURL: URL?
    public let signature: VideoUploaderSignatureContent

    public init(
        owner: VideoOwner,
        signatureState: VideoUploaderSignatureState? = nil
    ) {
        let normalizedName = Self.normalized(owner.name)
        name = normalizedName ?? "未知 UP 主"
        avatarURL = owner.avatarURL
        switch signatureState ?? .loaded(owner.signature) {
        case .loading:
            signature = .loading
        case .loaded(let value):
            signature =
                Self.normalized(value).map {
                    .text($0)
                } ?? .hidden
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized =
            value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}
