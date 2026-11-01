import Foundation

/// 封面左下角的一项指标（播放、弹幕数等）：已格式化的文字与 SF Symbol 名。
package struct NativeVideoCardMetric: Equatable, Sendable {
    package let text: String
    package let systemImage: String

    package init(text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }
}

/// 页脚尾部文字的样式。
package enum NativeVideoCardFooterTrailingStyle: Equatable, Sendable {
    /// 靠右的普通文字，前面可带小图标。
    case plain
    /// 品牌色描边胶囊，排在页脚最前（首页推荐理由），页脚文字随后。
    case brandOutlinedCapsule
}

/// 卡片能否进入播放：由调用方按业务判断给出，renderer 只按它呈现与拦截激活。
package enum NativeVideoCardAvailability: Equatable, Sendable {
    case available
    /// 不能进入播放：卡片变暗、不显示悬停与按下，点击、回车、空格与读屏按下都不激活；键盘选择仍可停在上面。
    /// `badge` 是调用方已本地化的原因，显示在封面角标上。
    case unavailable(badge: String)
}

/// AppKit 卡片唯一消费的、无业务语义的展示值。
///
/// Feature 的网格与横排包装（Browse、Library 与 VideoDetail）负责图片缩略地址、
/// 数字／日期／进度格式化与读屏文案；renderer 不读取 endpoint model，也不推断任何业务状态。
package struct NativeVideoCardPresentation: Equatable, Sendable {
    package let id: String
    package let title: String
    package let coverURL: URL?
    package let avatarURL: URL?
    package let showsAvatar: Bool
    package let coverMetrics: [NativeVideoCardMetric]
    package let coverTrailingText: String?
    package let footerLeadingText: String
    package let footerTrailingText: String?
    /// 尾部文字前的小图标（SF Symbol 名），只用于普通样式。
    package let footerTrailingSymbolName: String?
    package let footerTrailingStyle: NativeVideoCardFooterTrailingStyle
    package let accessibilityLabel: String
    package let accessibilityHelp: String?
    package let availability: NativeVideoCardAvailability

    /// 可进入播放；网格的激活入口与卡片的读屏按下都只看它。
    package var isActivatable: Bool { availability == .available }

    package init(
        id: String,
        title: String,
        coverURL: URL?,
        avatarURL: URL?,
        showsAvatar: Bool,
        coverMetrics: [NativeVideoCardMetric] = [],
        coverTrailingText: String? = nil,
        footerLeadingText: String,
        footerTrailingText: String? = nil,
        footerTrailingSymbolName: String? = nil,
        footerTrailingStyle: NativeVideoCardFooterTrailingStyle = .plain,
        accessibilityLabel: String,
        accessibilityHelp: String? = nil,
        availability: NativeVideoCardAvailability = .available
    ) {
        self.id = id
        self.title = title
        self.coverURL = coverURL
        self.avatarURL = avatarURL
        self.showsAvatar = showsAvatar
        // 封面只有两个指标位，多出的丢弃。
        self.coverMetrics = Array(coverMetrics.prefix(2))
        self.coverTrailingText = coverTrailingText
        self.footerLeadingText = footerLeadingText
        self.footerTrailingText = footerTrailingText
        self.footerTrailingSymbolName = footerTrailingSymbolName
        self.footerTrailingStyle = footerTrailingStyle
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHelp = accessibilityHelp
        self.availability = availability
    }
}

/// 复用卡片的身份：视频 ID 加卡片自己的配置代次，异步取图回来时据此判断卡片是否已改配。
struct NativeVideoReuseIdentity: Equatable {
    let itemID: String
    let generation: UInt64
}

/// 取图结果能否写回卡片：未取消，且卡片当前身份与发起时相同；否则丢弃结果。
enum NativeVideoImageApplicationGate {
    static func accepts(
        currentIdentity: NativeVideoReuseIdentity?,
        resultIdentity: NativeVideoReuseIdentity,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && currentIdentity == resultIdentity
    }
}
