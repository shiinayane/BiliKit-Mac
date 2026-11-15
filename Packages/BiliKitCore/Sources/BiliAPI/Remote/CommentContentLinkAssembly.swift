import BiliModels
import Foundation

/// 评论正文链接的拼装：按文字定位接口链接、去掉重叠，并给重叠时的取舍一个稳定顺序。
extension CommentContentPayload {
    /// `token` 在正文里的所有不重叠出现位置（UTF-16 偏移），供表情、接口链接与 @ 定位。
    func ranges(of token: String) -> [CommentTextRange] {
        guard !token.isEmpty else { return [] }
        let source = message as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        var result: [CommentTextRange] = []
        while searchRange.length > 0 {
            let range = source.range(of: token, options: [], range: searchRange)
            guard range.location != NSNotFound else { break }
            result.append(CommentTextRange(location: range.location, length: range.length))
            let next = NSMaxRange(range)
            searchRange = NSRange(location: next, length: source.length - next)
        }
        return result
    }

    /// 按起点、长度（长的优先）与目标类型排序后，依次保留不与上一个保留项重叠的链接。
    static func nonoverlappingLinks(_ links: [CommentLink]) -> [CommentLink] {
        let sorted = links.sorted {
            if $0.range.location != $1.range.location {
                return $0.range.location < $1.range.location
            }
            if $0.range.length != $1.range.length {
                return $0.range.length > $1.range.length
            }
            return linkOrderKey($0.target) < linkOrderKey($1.target)
        }
        var result: [CommentLink] = []
        for link in sorted {
            guard let previous = result.last else {
                result.append(link)
                continue
            }
            guard link.range.location >= previous.range.location + previous.range.length
            else { continue }
            result.append(link)
        }
        return result
    }

    private static func linkOrderKey(_ target: CommentLinkTarget) -> String {
        switch target {
        case .video(let bvid, let page, let startSeconds):
            "0:\(bvid):\(page.map(String.init) ?? ""):\(startSeconds.map(String.init) ?? "")"
        case .timestamp(let seconds, let page):
            "4:\(page.map(String.init) ?? ""):\(seconds)"
        case .member(let user):
            "1:\(user.id.rawValue)"
        case .space(let memberID):
            "2:\(memberID)"
        case .shortLink(let reference), .external(let reference):
            "3:\(reference.remoteURL.absoluteString)"
        }
    }
}
