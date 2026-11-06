import BiliModels
import BiliNetworking
import Foundation

/// 在评论正文的纯文字里识别接口没有标出的链接：网址、b23.tv 短链、BV 号、av 号与时间戳。
///
/// 只认 ASCII 字符组成的标记，紧邻的中文与全角标点不会被吞进链接；结果与接口链接（`jump_url`、
/// @ 提及）共用同一套分类。接口链接与表情覆盖的文字不再识别；网址整段先占位，即使它本身不能成为
/// 链接，里面的片段也不会被单独识别。
enum CommentTextLinkDetector {
    private struct Rule: Sendable {
        let pattern: NSRegularExpression
        /// 网址类匹配不论能否分类都占住整段文字。
        let claimsMatch: Bool
        let trimsURLPunctuation: Bool
        let target: @Sendable (String) -> CommentLinkTarget?
    }

    /// 按优先级排列：先网址，再不带协议头的短链，最后 BV 号与 av 号。
    ///
    /// 模式都是常量，编译失败属于编程错误，由 `compiled(_:)` 在首次使用时崩溃暴露，而不是让某条规则静默失效。
    /// 用 `NSRegularExpression` 而不用 Swift `Regex` 字面量：字面量不支持这里依赖的 lookbehind。
    private static let rules: [Rule] = [
        // `https://`／`http://` 开头的网址，只取 RFC 3986 允许的 ASCII 字符；不含 `[` `]`，网址后
        // 紧跟的表情（`[doge]`）不会被吞进来。原样中文路径在中文处截断。
        Rule(
            pattern: compiled(
                #"(?<![A-Za-z0-9])[Hh][Tt][Tt][Pp][Ss]?://[A-Za-z0-9\-._~:/?#@!$&'()*+,;=%]+"#
            ),
            claimsMatch: true,
            trimsURLPunctuation: true,
            target: urlTarget
        ),
        // 不带协议头的短链；前面紧挨字母、数字或网址字符时是别的网址或邮箱的一部分。
        Rule(
            pattern: compiled(
                #"(?<![A-Za-z0-9./@=?&])[Bb]23\.[Tt][Vv]/[A-Za-z0-9]+(?![A-Za-z0-9])"#
            ),
            claimsMatch: true,
            trimsURLPunctuation: false,
            target: bareShortLinkTarget
        ),
        // BV 号：`BV1` 加 9 位 base58 字符。
        Rule(
            pattern: compiled(
                #"(?<![A-Za-z0-9])BV1[1-9A-HJ-NP-Za-km-z]{9}(?![A-Za-z0-9])"#
            ),
            claimsMatch: false,
            trimsURLPunctuation: false,
            target: videoTarget
        ),
        // av 号至少 5 位数字：`AV1` 编码、`AV8` 型号这类短写法不是视频号。
        Rule(
            pattern: compiled(
                #"(?<![A-Za-z0-9])[Aa][Vv][0-9]{5,}(?![A-Za-z0-9])"#
            ),
            claimsMatch: false,
            trimsURLPunctuation: false,
            target: videoTarget
        ),
        // 时间戳：`h:mm:ss` 或 `m:ss`（分钟最多 3 位），秒与带小时时的分钟必须是两位且小于 60；
        // 分隔符半角、全角冒号都认，中文输入法下常打出全角。前面紧挨字母、数字或冒号时是型号、编号
        // 或更长数字串的一部分（`p1:23`、`x264:10`）；后面只排除数字与冒号，紧跟的字母多是单位或
        // 英文正文（`1:23s`、`1:23this`），与紧跟中文一样照常识别。是否超出可跳转时长到显示时再判断。
        Rule(
            pattern: compiled(
                #"(?<![A-Za-z0-9:：])(?:[0-9]{1,2}[:：][0-5][0-9][:：][0-5][0-9]|[0-9]{1,3}[:：][0-5][0-9])(?![0-9:：])"#
            ),
            claimsMatch: false,
            trimsURLPunctuation: false,
            target: timestampTarget
        )
    ]

    /// 编译常量模式；失败只可能是模式写错，用 `preconditionFailure` 终止（仓库禁用 `try!`），不返回可选值。
    private static func compiled(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("评论正文链接的正则模式无法编译：\(error)")
        }
    }

    /// 网址末尾常跟着句读，不算网址的一部分；右括号只在不成对时剔除。
    private static let trailingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "'", "\""
    ]

    /// 识别出的链接，不与 `excluded`（接口链接与表情的范围）重叠；按出现位置排序。
    static func links(in message: String, excluding excluded: [CommentTextRange]) -> [CommentLink] {
        let source = message as NSString
        var taken = excluded
        var result: [CommentLink] = []
        for rule in rules {
            let matches = rule.pattern.matches(
                in: message,
                range: NSRange(location: 0, length: source.length)
            )
            for match in matches {
                let nsRange =
                    rule.trimsURLPunctuation
                    ? trimmedURLRange(match.range, in: source) : match.range
                let range = CommentTextRange(location: nsRange.location, length: nsRange.length)
                guard range.length > 0, !taken.contains(where: { overlaps($0, range) }) else {
                    continue
                }
                let target = rule.target(source.substring(with: nsRange))
                if rule.claimsMatch || target != nil {
                    taken.append(range)
                }
                if let target {
                    result.append(CommentLink(range: range, target: target))
                }
            }
        }
        return result.sorted { $0.range.location < $1.range.location }
    }

    /// 网址按评论链接规则分类。
    ///
    /// `http` 只在指向站内目标时升级为 HTTPS，否则不生成链接；外链必须能通过公开 HTTPS 复核，
    /// 避免显示成点了没反应的链接。
    private static func urlTarget(_ text: String) -> CommentLinkTarget? {
        let (secure, isInsecure) = RemoteURLString.upgradingInsecureHTTP(text)
        guard let target = CommentRemoteLink.target(secure) else { return nil }
        switch target {
        case .video, .member, .space, .shortLink, .timestamp:
            return target
        case .external(let reference):
            guard !isInsecure, BiliCommentLinkResolver().externalURL(for: reference) != nil
            else { return nil }
            return target
        }
    }

    /// 不带协议头的只认合规短链；形状不符时不当作外链。
    private static func bareShortLinkTarget(_ text: String) -> CommentLinkTarget? {
        guard case .shortLink(let reference)? = CommentRemoteLink.target("https://\(text)") else {
            return nil
        }
        return .shortLink(reference)
    }

    private static func timestampTarget(_ text: String) -> CommentLinkTarget? {
        let parts = text.split { $0 == ":" || $0 == "：" }
        let seconds = parts.reduce(0) { total, part in
            total * 60 + (Int(part) ?? 0)
        }
        return .timestamp(seconds: seconds)
    }

    private static func videoTarget(_ text: String) -> CommentLinkTarget? {
        CommentRemoteLink.bvid(fromVideoID: text).map {
            .video(bvid: $0, page: nil, startSeconds: nil)
        }
    }

    private static func trimmedURLRange(_ range: NSRange, in source: NSString) -> NSRange {
        var text = source.substring(with: range)
        while let last = text.last {
            if trailingPunctuation.contains(last) {
                text.removeLast()
            } else if last == ")", text.count(of: ")") > text.count(of: "(") {
                text.removeLast()
            } else {
                break
            }
        }
        return NSRange(location: range.location, length: (text as NSString).length)
    }

    private static func overlaps(_ lhs: CommentTextRange, _ rhs: CommentTextRange) -> Bool {
        lhs.location < rhs.location + rhs.length && rhs.location < lhs.location + lhs.length
    }
}

extension String {
    fileprivate func count(of character: Character) -> Int {
        reduce(0) { $1 == character ? $0 + 1 : $0 }
    }
}
