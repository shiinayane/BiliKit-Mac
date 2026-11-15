import BiliModels
import BiliVideoDetailFeature
import Foundation
import Observation

/// 侧栏的平级来源，也是来源描述（`AppSourceDescriptor`）的 id；case 的声明顺序就是同一侧栏分组内的顺序，
/// 分组之间的顺序由 `AppSourceGroup` 固定。
enum AppTab: Hashable, CaseIterable {
    case search
    case home
    case popular
    case watchLater
    case history
    /// 收藏夹：侧栏「收藏夹」组里每个收藏夹一行（`AppSidebarSelection.item`），选中的收藏夹记在收藏夹模型里。
    case favorites
}

/// 协调窗口内的顶层 Tab、右侧是否在播放页、播放生命周期副作用与侧栏上下文层。
///
/// Coordinator 不拥有播放器：开始与停止播放经 `WindowComposition` 注入的闭包交给视频与弹幕模型。
/// 右侧只渲染当前页（来源根页或播放页，见 docs/ARCHITECTURE.md「动线与侧栏上下文层」），`activePlayback` 非 nil
/// 就是播放页，它同时是播放页里的媒体 identity；换视频只替换它。工具栏返回（`goBack()`）、切换来源、登出与关窗都经
/// `closePlayback()` 这一条播放副作用边界收口。侧栏上下文层（UP 主空间）
/// 的打开与关闭入口都在这里，是否打开从空间模型的 `owner` 派生；
/// 空间模型自己在返回按钮或账户会话切换时关闭，同样反映到 `isSidebarContextOpen`。
@MainActor
@Observable
final class AppNavigationCoordinator {
    var selectedTab: AppTab = .home {
        didSet {
            guard selectedTab != oldValue else { return }
            closePlayback()
        }
    }
    var currentPlaybackBVID: String? {
        activePlayback?.bvid
    }
    var currentPlaybackIntent: PlaybackSelectionIntent? {
        activePlayback
    }
    /// 侧栏上下文层的内容模型；每个窗口都有，空间入口与空间链接都在这里打开。
    @ObservationIgnored let uploaderSpace: UploaderSpaceViewModel
    /// 上下文层是否打开：底层要隐藏、侧栏要叠上空间列表。
    var isSidebarContextOpen: Bool {
        uploaderSpace.owner != nil
    }

    /// 播放页当前的选择意图；nil 表示右侧是来源根页。
    private var activePlayback: PlaybackSelectionIntent?
    @ObservationIgnored private let startPlayback: (PlaybackSelectionIntent) -> Void
    @ObservationIgnored private let stopPlayback: () -> Void

    /// - Parameters:
    ///   - startPlayback: 开始或替换当前视频。
    ///   - stopPlayback: 关闭播放后停止播放器与弹幕。
    ///   - uploaderSpace: 侧栏上下文层（UP 主空间）的模型。上下文层只在播放时存在，关闭播放、或从
    ///     上下文层以外的入口换视频时关闭它。
    init(
        startPlayback: @escaping (PlaybackSelectionIntent) -> Void,
        stopPlayback: @escaping () -> Void,
        uploaderSpace: UploaderSpaceViewModel
    ) {
        self.startPlayback = startPlayback
        self.stopPlayback = stopPlayback
        self.uploaderSpace = uploaderSpace
    }

    /// 在侧栏上下文层打开某位 UP 主的空间（播放侧栏的 UP 主行、评论作者与 @ 提及）。
    func openUploaderSpace(owner: VideoOwner) {
        uploaderSpace.open(owner: owner)
    }

    /// 只有 MID 的入口（评论正文里的空间链接）：先以 UID 作头部打开，名片到达后补上名字与头像。
    func openUploaderSpace(ownerID: Int64) {
        uploaderSpace.open(ownerID: ownerID)
    }

    /// 首次打开进入播放页；已在播放页时只替换媒体 identity。
    func openPlayback(_ bvid: String) {
        openPlayback(PlaybackSelectionIntent(bvid: bvid))
    }

    /// 播放页侧栏的选分 P、选集：在当前视频里换分 P，或换到合集里的另一集；离开侧栏上下文层。
    func openPlayback(_ bvid: String, preferredCID: Int64?) {
        openPlayback(PlaybackSelectionIntent(bvid: bvid, preferredCID: preferredCID))
    }

    /// 播完后的自动连播与列表循环：与侧栏选分 P、选集同一意图，但不是用户从别处换视频，侧栏上下文层保留。
    func continuePlayback(_ bvid: String, preferredCID: Int64?) {
        openPlayback(
            PlaybackSelectionIntent(bvid: bvid, preferredCID: preferredCID),
            preservesSidebarContext: true
        )
    }

    /// 从侧栏上下文层（UP 主空间）里选择视频：用户仍在逛这个空间，上下文层保留。
    func openPlaybackFromSidebarContext(_ bvid: String) {
        openPlayback(PlaybackSelectionIntent(bvid: bvid), preservesSidebarContext: true)
    }

    /// 来源页、相关推荐、选集、评论链接等入口换视频：用户已离开上下文层，关闭它退回详情。
    ///
    /// 按“从哪里打开”判断，不比较新视频的 UP 主：联合投稿的 UP 主字段可能是另一位。
    /// 重新点击正在播放的视频同样算离开上下文层。
    func openPlayback(_ intent: PlaybackSelectionIntent) {
        openPlayback(intent, preservesSidebarContext: false)
    }

    private func openPlayback(
        _ intent: PlaybackSelectionIntent,
        preservesSidebarContext: Bool
    ) {
        guard !intent.bvid.isEmpty else { return }
        if !preservesSidebarContext {
            closeSidebarContext()
        }
        guard activePlayback != intent else { return }
        activePlayback = intent
        startPlayback(intent)
    }

    func retryPlayback() {
        guard let intent = currentPlaybackIntent else { return }
        startPlayback(intent)
    }

    /// 工具栏「返回」：离开播放页回到来源根页；不在播放页时不动作，所以连点只停止一次。
    func goBack() {
        closePlayback()
    }

    /// 登出只关闭当前播放，不改变来源 Tab。
    func closePlaybackForAuthenticationChange() {
        closePlayback()
    }

    /// 关闭当前播放，并恢复一个新窗口应有的来源。
    func resetForWindowClosure() {
        closePlayback()
        selectedTab = .home
    }

    private func closePlayback() {
        guard activePlayback != nil else { return }
        activePlayback = nil
        closeSidebarContext()
        stopPlayback()
    }

    private func closeSidebarContext() {
        uploaderSpace.close()
    }
}
