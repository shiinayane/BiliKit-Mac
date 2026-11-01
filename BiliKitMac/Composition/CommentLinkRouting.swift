import BiliAPI
import BiliModels
import BiliVideoDetailFeature
import Foundation

/// 评论正文链接的去向，由 Composition 按链接目标翻译；App 外壳只执行，不接触评论模型。
enum CommentLinkRoute: Sendable {
    case playback(PlaybackSelectionIntent)
    /// 正文时间戳：在当前视频正在播的分 P 里跳到该秒数并播放。
    case seek(seconds: Int)
    /// 在右栏空间层打开。
    case space(memberID: Int64)
    case web(URL)
    /// 短链：点击后由 `resolve` 解析出真正的去向；解析不出时打开 `webFallback`（原短链）。
    case shortLink(resolve: @Sendable () async -> CommentLinkRoute?, webFallback: URL?)
}

typealias CommentLinkRouter = @Sendable (CommentLinkTarget) -> CommentLinkRoute?

/// 评论链接目标到 App 路由的唯一翻译处。
///
/// 每个窗口一份，由 `WindowAdapters.live` 构造；`shortLinkResolver` 持有本窗口的短链 session，
/// 关窗时由 adapter 的 `close` 失效（见 SECURITY-MODEL §4）。短链解析的在途 Task 不在这里，归
/// `CommentShortLinkResolution`。
struct CommentLinkRouting: Sendable {
    let linkResolver: BiliCommentLinkResolver
    let shortLinkResolver: BiliShortLinkResolver

    func route(for target: CommentLinkTarget) -> CommentLinkRoute? {
        switch target {
        case .video(let bvid, let page, let startSeconds):
            return .playback(
                PlaybackSelectionIntent(
                    bvid: bvid,
                    preferredPageNumber: page,
                    preferredStartSeconds: startSeconds
                )
            )
        case .timestamp(let seconds):
            return .seek(seconds: seconds)
        case .space(let memberID):
            return .space(memberID: memberID)
        case .member(let user):
            // 播放详情区已把 @ 提及直接打开为空间；经这里的同样进空间，非正整数 MID 没有去向。
            return user.id.memberID.map { .space(memberID: $0) }
        case .external(let reference):
            return linkResolver.externalURL(for: reference).map(CommentLinkRoute.web)
        case .shortLink(let reference):
            let routing = self
            return .shortLink(
                resolve: {
                    // 解析结果不会再是短链；其余目标与正文里的链接走同一翻译。
                    await shortLinkResolver.resolve(target).flatMap(routing.route(for:))
                },
                webFallback: linkResolver.externalURL(for: reference)
            )
        }
    }
}
