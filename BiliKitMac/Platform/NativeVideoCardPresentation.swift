import Foundation

struct NativeVideoCardMetric: Equatable, Sendable {
    let text: String
    let systemImage: String
}

/// AppKit 卡片唯一消费的、无业务语义的展示值。
///
/// Feature 或 composition adapter 负责图片 URL 优化、数字/日期/进度格式化与 AX 文案；
/// renderer 不读取 endpoint model，也不推断任何业务状态。
struct NativeVideoCardPresentation: Equatable, Sendable {
    let id: String
    let title: String
    let coverURL: URL?
    let avatarURL: URL?
    let showsAvatar: Bool
    let coverMetrics: [NativeVideoCardMetric]
    let coverTrailingText: String?
    let footerLeadingText: String
    let footerTrailingText: String?
    let accessibilityLabel: String
    let accessibilityHelp: String?

    init(
        id: String,
        title: String,
        coverURL: URL?,
        avatarURL: URL?,
        showsAvatar: Bool,
        coverMetrics: [NativeVideoCardMetric] = [],
        coverTrailingText: String? = nil,
        footerLeadingText: String,
        footerTrailingText: String? = nil,
        accessibilityLabel: String,
        accessibilityHelp: String? = nil
    ) {
        self.id = id
        self.title = title
        self.coverURL = coverURL
        self.avatarURL = avatarURL
        self.showsAvatar = showsAvatar
        self.coverMetrics = Array(coverMetrics.prefix(2))
        self.coverTrailingText = coverTrailingText
        self.footerLeadingText = footerLeadingText
        self.footerTrailingText = footerTrailingText
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHelp = accessibilityHelp
    }
}

struct NativeVideoReuseIdentity: Equatable {
    let itemID: String
    let generation: UInt64
}

enum NativeVideoImageApplicationGate {
    static func accepts(
        currentIdentity: NativeVideoReuseIdentity?,
        resultIdentity: NativeVideoReuseIdentity,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && currentIdentity == resultIdentity
    }
}
