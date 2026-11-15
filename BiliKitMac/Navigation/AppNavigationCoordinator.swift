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

/// 进出播放页时页面切换的方向，供视图层选择转场；同类替换、换来源、登出与关窗不转场。
enum AppPageTransition {
    case push
    case pop
}

/// 协调窗口内的顶层 Tab、右侧是否在播放页、播放生命周期副作用与侧栏上下文层。
///
/// Coordinator 不拥有播放器：开始、暂停与停止播放经 `WindowComposition` 注入的闭包交给视频与弹幕模型，转场同样经
/// 注入的闭包交给视图层。右侧只渲染当前页（来源根页或播放页，见 docs/ARCHITECTURE.md「播放页布局」），
/// `activePlayback` 非 nil 就是播放页，它同时是播放页里的媒体 identity；换视频只替换它。切换来源、登出与关窗经
/// `closePlayback()` 立即停止；工具栏返回（`goBack()`）在有画面可留时先暂停、转场结束后再停止，这次延后的停止由
/// 之后任何一次进入播放页或 `closePlayback()` 提前完成。
/// 侧栏上下文层（UP 主空间）的打开与关闭入口都在这里，是否打开从空间模型的 `owner` 派生；空间模型自己在返回按钮
/// 或账户会话切换时关闭，同样反映到 `isSidebarContextOpen`。
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
    /// 返回时延后的停止是否还没执行。
    @ObservationIgnored private var hasPendingStop = false
    /// 延后停止的代次：每次发出延后停止与提前完成它时递增；转场结束的回调只在代次未变时停止，否则说明这次停止已被
    /// 提前完成（又进了播放页、换来源、登出或关窗），丢弃回调，不会停掉之后的播放。
    @ObservationIgnored private var pendingStopGeneration: UInt64 = 0
    @ObservationIgnored private let startPlayback: (PlaybackSelectionIntent) -> Void
    @ObservationIgnored private let stopPlayback: () -> Void
    @ObservationIgnored private let pausePlayback: () -> Bool
    @ObservationIgnored private let transitionPage:
        (AppPageTransition, _ change: () -> Void, _ completion: @escaping () -> Void) -> Void

    /// - Parameters:
    ///   - startPlayback: 开始或替换当前视频。
    ///   - stopPlayback: 关闭播放后停止播放器与弹幕。
    ///   - pausePlayback: 返回时暂停播放器，画面停在当前帧随旧页离开；还没有呈现中的画面（仍在加载）时不暂停并返回
    ///     false，返回改为立即停止：这时没有画面可留，暂停也拦不住随后加载完成的自动起播。
    ///   - transitionPage: 进出播放页的转场。必须同步调用 `change` 恰好一次，转场结束（或没有转场）后调用 `completion`
    ///     恰好一次；`completion` 可以晚于本次调用。
    ///   - uploaderSpace: 侧栏上下文层（UP 主空间）的模型。上下文层只在播放时存在，关闭播放、或从
    ///     上下文层以外的入口换视频时关闭它。
    init(
        startPlayback: @escaping (PlaybackSelectionIntent) -> Void,
        stopPlayback: @escaping () -> Void,
        pausePlayback: @escaping () -> Bool,
        transitionPage:
            @escaping (
                AppPageTransition, _ change: () -> Void, _ completion: @escaping () -> Void
            ) -> Void,
        uploaderSpace: UploaderSpaceViewModel
    ) {
        self.startPlayback = startPlayback
        self.stopPlayback = stopPlayback
        self.pausePlayback = pausePlayback
        self.transitionPage = transitionPage
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
    ///
    /// 只在播放页里生效：下一集要先解析，用户在解析回来之前已经返回时，不把用户拉回播放页。
    func continuePlayback(_ bvid: String, preferredCID: Int64?) {
        guard activePlayback != nil else { return }
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
        // 返回的转场还没结束就又进了播放页：先完成上一次停止，与立即停止后再开始一样，不让旧视频的停止晚到。
        completePendingStop()
        if activePlayback == nil {
            transitionPage(.push, { activePlayback = intent }, {})
        } else {
            activePlayback = intent
        }
        startPlayback(intent)
    }

    func retryPlayback() {
        guard let intent = currentPlaybackIntent else { return }
        startPlayback(intent)
    }

    /// 工具栏「返回」：离开播放页回到来源根页；不在播放页时不动作，所以连点只停止一次。
    ///
    /// 先暂停，再转场换页，转场结束后才停止：停止播放会立即清空画面，放在换页的同一次提交里时，旧页面带着黑掉的
    /// 视频区离开。还没有画面可留时（`pausePlayback` 返回 false）照样转场，但立即停止。
    func goBack() {
        guard activePlayback != nil else { return }
        guard pausePlayback() else {
            transitionPage(.pop, { leavePlaybackPage() }, {})
            stopPlayback()
            return
        }
        hasPendingStop = true
        pendingStopGeneration &+= 1
        let generation = pendingStopGeneration
        transitionPage(
            .pop,
            { leavePlaybackPage() },
            { [weak self] in
                guard let self, self.hasPendingStop, self.pendingStopGeneration == generation else {
                    return
                }
                self.hasPendingStop = false
                self.stopPlayback()
            }
        )
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
        completePendingStop()
        guard activePlayback != nil else { return }
        leavePlaybackPage()
        stopPlayback()
    }

    /// 右侧回到来源根页，并关闭只在播放时存在的侧栏上下文层；不碰播放器。
    private func leavePlaybackPage() {
        activePlayback = nil
        closeSidebarContext()
    }

    /// 提前完成返回时延后的停止；没有延后的停止时不动作。
    private func completePendingStop() {
        guard hasPendingStop else { return }
        hasPendingStop = false
        pendingStopGeneration &+= 1
        stopPlayback()
    }

    private func closeSidebarContext() {
        uploaderSpace.close()
    }
}
