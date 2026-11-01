import BiliVideoDetailFeature
import Foundation

/// 执行评论与简介正文链接的路由（`CommentLinkRoute`，由 Composition 的 `CommentLinkRouting` 翻译）：视频（含分 P）
/// 在应用内播放，空间链接在右栏空间层打开，其余交给系统浏览器。
///
/// 只持有窗口级依赖的引用，不拥有状态：导航与上下文层归 `AppNavigationCoordinator`，链接起播能否原地跳转由
/// `VideoViewModel` 判断，短链的在途解析归窗口级 `CommentShortLinkResolution`（换视频与关窗时取消）。
/// `seekPlayback` 只在播放器 item 仍属该视频时跳转；`openURL` 是系统的 `OpenURLAction`，只在用户点击后调用，
/// 见 SECURITY-MODEL §4。
@MainActor
struct CommentLinkOpener {
    let navigationCoordinator: AppNavigationCoordinator
    let videoModel: VideoViewModel
    let shortLinks: CommentShortLinkResolution
    let seekPlayback: @MainActor (_ bvid: String, _ seconds: Int) -> Void
    let openURL: @MainActor (URL) -> Void

    /// 按路由执行一次点击。
    ///
    /// 空间链接在右栏空间层打开。短链先由窗口级 owner 解析，解析出的路由再走这里一次，
    /// 解析不出时打开原短链。时间戳与指向正在播放分 P 的 `t=` 直接跳转，不经过导航去重，
    /// 同一个时间点可以反复点。
    func open(_ route: CommentLinkRoute?) {
        switch route {
        case .playback(let intent):
            if let seconds = videoModel.inPlaceStartSeconds(
                for: intent,
                currentPlaybackBVID: navigationCoordinator.currentPlaybackBVID
            ) {
                seekPlayback(intent.bvid, seconds)
            } else {
                navigationCoordinator.openPlayback(intent)
            }
        case .seek(let seconds):
            if let bvid = navigationCoordinator.currentPlaybackBVID {
                seekPlayback(bvid, seconds)
            }
        case .space(let memberID):
            navigationCoordinator.openUploaderSpace(ownerID: memberID)
        case .web(let url):
            openURL(url)
        case .shortLink(let resolve, let webFallback):
            shortLinks.start(resolve) { resolved in
                open(resolved ?? webFallback.map(CommentLinkRoute.web))
            }
        case nil:
            break
        }
    }
}
