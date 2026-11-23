import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// 评论 `jump_url` 的一项：键是正文里被替换的文字，值给出去向。
struct CommentJumpURLPayload: Decodable, Sendable {
    let pcURL: String?
    /// 搜索词链接：去向是正文里这段文字本身（`CommentRemoteLink.searchKeyword`），点击后压一层搜索结果页。
    let isWordSearch: Bool
    /// 官方客户端显示的标题（如短链指向的视频名），已还原 HTML 实体（见 `RemoteHTMLText`）。
    let title: String?
    /// 显示在链接前的小图标地址。
    let prefixIcon: String?
    /// 正文里同一段文字多次出现时只链接第一处。
    let matchesOnce: Bool

    private enum CodingKeys: String, CodingKey {
        case pcURL = "pc_url"
        case extra
        case title
        case prefixIcon = "prefix_icon"
        case matchOnce = "match_once"
    }

    private struct ExtraPayload: Decodable, Sendable {
        let isWordSearch: Bool?

        private enum CodingKeys: String, CodingKey {
            case isWordSearch = "is_word_search"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isWordSearch = container.decodeLossyBool(forKey: .isWordSearch)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pcURL = try container.decodeIfPresent(String.self, forKey: .pcURL)
        let extra = try? container.decodeIfPresent(ExtraPayload.self, forKey: .extra)
        isWordSearch = extra?.isWordSearch == true
        // 标题、图标与只链接一次都只影响显示，字段异常时按缺省处理，不拖累链接本身。
        title = (try? container.decodeIfPresent(String.self, forKey: .title))
            .map(RemoteHTMLText.plainText)
        prefixIcon = try? container.decodeIfPresent(String.self, forKey: .prefixIcon)
        matchesOnce = container.decodeLossyBool(forKey: .matchOnce) ?? false
    }

    /// 替换正文原文显示的标题：去掉首尾空白后非空、且与原文不同时才替换。
    ///
    /// `label` 须是已还原实体的正文文字，与同样已还原的 `title` 比较，转义写法不同的同一段文字不算不同。
    ///
    /// 站外链接不替换，正文保留真实网址，点击前能看到要去的域名。
    func displayTitle(label: String, target: CommentLinkTarget) -> String? {
        if case .external = target { return nil }
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty, title != label
        else { return nil }
        return title
    }

    /// 前置小图标的资源引用；来源限制在解析图片地址时统一复核，这里只拒绝带用户信息的地址。
    var icon: CommentAssetReference? {
        guard let url = prefixIcon.flatMap(WebImageURL.parse),
            url.user == nil, url.password == nil
        else { return nil }
        return CommentAssetReference(remoteURL: url)
    }

    /// 链接地址：`pc_url` 缺失或为空时，正文里的网址本身（如 b23.tv 短链）就是键，退回用键。
    ///
    /// 键不是 HTTPS 网址时由分类规则拒绝，不会生成链接。
    func destination(label: String) -> String {
        guard let pcURL, !pcURL.isEmpty else { return label }
        return pcURL
    }
}

/// 把评论与简介里的链接地址分成站内视频、UP 主空间、b23.tv 短链与其他 HTTPS 外链。
///
/// 只接受 HTTPS 且不带 userinfo 的地址（协议相对地址补 `https:`）。站内目标按未解码的 host 与 path
/// 精确匹配，不带端口；BVID 原样校验或由 av 号本地换算，空间只认正整数 MID；形状不符时不猜测，
/// 按外链处理（见 SECURITY-MODEL §4）。
enum CommentRemoteLink {
    /// 搜索词链接的关键词：正文里这段文字按搜索规则规范化；为空或超过长度上限时不生成链接。
    ///
    /// 超长不截断：截断后搜的就不是正文里看到的那段文字了（见 SECURITY-MODEL §4）。
    static func searchKeyword(label: String) -> String? {
        let keyword = SearchText.normalized(label)
        guard !keyword.isEmpty, SearchText.isWithinLimit(keyword) else { return nil }
        return keyword
    }

    /// 视频页所在的主机：桌面版、手机版与不带 `www` 的裸域。
    private static let videoHosts: Set<String> = [
        "www.bilibili.com", "m.bilibili.com", "bilibili.com"
    ]
    private static let spaceHost = "space.bilibili.com"
    /// 空间里与应用内空间层（投稿列表）对应的子页面；合集、收藏夹、动态等其他子页面交给浏览器。
    private static let spaceVideoListPaths: Set<[String]> = [[], ["video"], ["upload", "video"]]

    /// 短链主机；`bili2233.cn` 等其他短链域名不认，按外链处理。
    private static let shortLinkHost = "b23.tv"
    /// 短码只允许 ASCII 字母与数字，长度 1–16；调大会让更长的路径也被当作短链发出 `HEAD`，
    /// 形状不符的按外链处理。
    private static let maximumShortLinkCodeLength = 16

    static func target(_ value: String?) -> CommentLinkTarget? {
        guard let components = components(value) else { return nil }
        if let target = internalTarget(components) {
            return target
        }
        guard let url = components.url else { return nil }
        if shortLinkURL(components) != nil {
            return .shortLink(CommentExternalLinkReference(remoteURL: url))
        }
        return .external(CommentExternalLinkReference(remoteURL: url))
    }

    /// 合规短链的请求地址：只保留 `https://b23.tv/{短码}`，去掉 query 与 fragment；形状不符时为 nil。
    ///
    /// 由 `BiliShortLinkResolver` 在发出无凭据 `HEAD` 前调用（见 SECURITY-MODEL §4）。
    static func shortLinkRequestURL(_ url: URL) -> URL? {
        URLComponents(url: url, resolvingAgainstBaseURL: false).flatMap(shortLinkURL)
    }

    /// 地址是否在短链主机上，不论形状；短链解析不追第二跳。
    static func isOnShortLinkHost(_ url: URL?) -> Bool {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .percentEncodedHost?.lowercased() == shortLinkHost
    }

    private static func shortLinkURL(_ components: URLComponents) -> URL? {
        guard components.scheme?.lowercased() == "https",
            components.user == nil, components.password == nil, components.port == nil,
            components.percentEncodedHost?.lowercased() == shortLinkHost
        else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/")
        guard parts.count == 1, let code = parts.first,
            (1...maximumShortLinkCodeLength).contains(code.count),
            code.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            })
        else { return nil }
        return URL(string: "https://\(shortLinkHost)/\(code)")
    }

    private static func internalTarget(_ components: URLComponents) -> CommentLinkTarget? {
        guard components.port == nil, let host = components.percentEncodedHost?.lowercased()
        else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/").map(String.init)
        if videoHosts.contains(host), parts.count == 2, parts[0] == "video",
            let bvid = bvid(fromVideoID: parts[1])
        {
            return .video(
                bvid: bvid,
                page: positiveQueryInteger("p", in: components),
                startSeconds: positiveQueryInteger("t", in: components)
            )
        }
        let memberID: Int64?
        if host == spaceHost, let first = parts.first,
            spaceVideoListPaths.contains(Array(parts.dropFirst()))
        {
            memberID = Int64(positiveDecimal: first)
        } else if host == "m.bilibili.com", parts.count == 2, parts[0] == "space" {
            memberID = Int64(positiveDecimal: parts[1])
        } else {
            memberID = nil
        }
        return memberID.map { .space(memberID: $0) }
    }

    /// 视频号：`BV…` 原样校验；`av…` 在本地换算为 BV 号。
    ///
    /// 链接路径与正文纯文字识别共用这一规则。
    static func bvid(fromVideoID component: String) -> String? {
        if BVID.isValid(component) {
            return component
        }
        guard component.lowercased().hasPrefix("av"),
            let aid = Int64(positiveDecimal: component.dropFirst(2))
        else { return nil }
        return BiliVideoAID.bvid(fromAID: aid)
    }

    /// 链接里的分 P 序号（`p`）与起播秒数（`t`）只是偏好：只认正整数，其他写法（小数、`1m30s`）
    /// 忽略，按视频默认分 P／位置打开。
    private static func positiveQueryInteger(_ name: String, in components: URLComponents) -> Int? {
        guard let value = components.queryItems?.first(where: { $0.name == name })?.value,
            let number = Int64(positiveDecimal: value)
        else { return nil }
        return Int(exactly: number)
    }

    private static func components(_ value: String?) -> URLComponents? {
        guard let value, !value.isEmpty,
            let components = URLComponents(
                string: RemoteURLString.resolvingProtocolRelative(value)
            ),
            components.scheme?.lowercased() == "https",
            components.host != nil,
            components.user == nil,
            components.password == nil
        else { return nil }
        return components
    }
}
