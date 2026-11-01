import AppKit
import BiliApplication
import BiliModels

/// 评论正文与简介共用的链接属性：链接值按序号编码，点击时解码回目标；超出可跳转时长的时间戳不加链接。
///
/// 链接值只是内部序号，不能交给系统当地址显示：文本视图经 `configure` 关掉系统链接提示，需要提示的链接由
/// `apply` 另加 `.toolTip`。
@MainActor
enum NativePlaybackTextLinks {
    private static let valuePrefix = "bilikit-comment-link-"

    /// 评论正文与简介文本视图的链接配置，两者在初始化时各调用一次。
    ///
    /// 替换系统默认链接样式时要带上手形指针，否则链接（含 @）悬停时仍是文本光标；手形只用在这里：
    /// HIG 只给链接用手形，卡片、列表行与作者入口等应用内点击区保持箭头。系统链接提示会把序号原样弹出，
    /// 必须关掉。
    static func configure(_ textView: NSTextView) {
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand
        ]
        textView.displaysLinkToolTips = false
    }

    /// 给链接原文加链接属性与悬停提示；返回点击时按序号查找的目标，以及实际加上的链接。
    ///
    /// `timestampLimitSeconds` 是可跳转上限（不含），超出或为 nil 时时间戳按普通文字显示。
    static func apply(
        _ links: [CommentLink],
        to attributed: NSMutableAttributedString,
        timestampLimitSeconds: Int?
    ) -> (targets: [CommentLinkTarget], applied: [CommentLink]) {
        var targets: [CommentLinkTarget] = []
        var applied: [CommentLink] = []
        for link in links {
            let range = NSRange(location: link.range.location, length: link.range.length)
            guard range.location >= 0, range.length > 0,
                NSMaxRange(range) <= attributed.length
            else { continue }
            if case .timestamp(let seconds) = link.target,
                !VideoContext.accepts(
                    seconds: seconds,
                    seekableDurationSeconds: timestampLimitSeconds
                )
            {
                continue
            }
            attributed.addAttribute(.link, value: "\(valuePrefix)\(targets.count)", range: range)
            if let toolTip = toolTip(for: link.target) {
                attributed.addAttribute(.toolTip, value: toolTip, range: range)
            }
            targets.append(link.target)
            applied.append(link)
        }
        return (targets, applied)
    }

    /// 站外链接与 b23.tv 短链提示真实地址，应用内目标不提示。
    ///
    /// 点开前能看到要去的域名；短链的文字常被换成视频标题，只有提示能看出它是短链。视频、@、空间与时间戳
    /// 都在应用内打开，文字已说明去处，提示网页地址反而像要打开浏览器。
    private static func toolTip(for target: CommentLinkTarget) -> String? {
        switch target {
        case .external(let reference), .shortLink(let reference):
            reference.remoteURL.absoluteString
        case .video, .timestamp, .member, .space:
            nil
        }
    }

    /// 点击时系统交回的链接值对应的目标；不是本类型编码的值时为 nil。
    static func target(for value: Any, in targets: [CommentLinkTarget]) -> CommentLinkTarget? {
        guard let value = value as? String,
            value.hasPrefix(valuePrefix),
            let index = Int(value.dropFirst(valuePrefix.count)),
            targets.indices.contains(index)
        else { return nil }
        return targets[index]
    }

    /// 有没有时间戳链接；只有这些文字随分 P 时长变化需要重新配置。
    nonisolated static func containsTimestamp(_ links: [CommentLink]) -> Bool {
        links.contains { link in
            if case .timestamp = link.target { return true }
            return false
        }
    }
}
