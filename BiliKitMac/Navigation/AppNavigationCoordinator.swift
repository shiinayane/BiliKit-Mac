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
    /// 关注：侧栏「关注」组里「全部关注」与每个分组一行（`AppSidebarSelection.item`），选中的行记在关注会话里。
    case follows
    /// 收藏夹：侧栏「收藏夹」组里每个收藏夹一行（`AppSidebarSelection.item`），选中的收藏夹记在收藏夹模型里。
    case favorites
}

/// 进出页面时页面切换的方向，供视图层选择转场；同类替换、换来源、登出与关窗不转场。
///
/// 移动的总是历史里的页（压一层时是压进来的新栈顶，弹出时是弹出去的旧栈顶），根页从不移动；历史页都铺不透明底色，
/// 所以视图层只按方向选转场（见 ARCHITECTURE「播放页布局」）。
enum AppPageTransition {
    case push
    case pop
}

/// 右侧历史里一页的内容；来源根页不在历史里。
///
/// 播放页是内容类页面（侧栏是它的详情），空间页是浏览类页面（侧栏是来源导航）。
enum AppDestination: Equatable {
    /// 播放页：选择意图。活视频被新视频取代时，换成带离开时分 P 与秒数的意图，回到这一页时按它重建。
    case playback(PlaybackSelectionIntent)
    /// 整页 UP 主空间：回到这一页时按记下的排序与搜索词重建。
    case uploaderSpace(UploaderSpaceDestination)
}

/// 整页空间页这一项记下的内容条件；页面上改排序或搜索时，在模型被另一项占用之前写回这里。
struct UploaderSpaceDestination: Equatable {
    var owner: VideoOwner
    var order: UploaderVideoOrder
    var searchKeyword: String?
}

/// 右侧历史里的一项。
///
/// `id` 在压入时分配，窗口内不重复；同类原地替换只改 `destination`、保留 `id`。活视频按 `id` 绑定在某一项上，
/// 不按内容查找：同一个视频可以在历史里出现不止一次。
struct AppHistoryEntry: Identifiable, Equatable {
    let id: UInt64
    var destination: AppDestination
}

/// 协调器驱动播放的入口，由 `WindowComposition` 构造；协调器不拥有播放器。
struct AppPlaybackSession {
    /// 开始或替换活视频。
    let start: (PlaybackSelectionIntent) -> Void
    /// 停止播放器与弹幕。
    let stop: () -> Void
    /// 暂停，让画面停在当前帧随旧页离开；还没有呈现中的画面（仍在加载）时不暂停并返回 false：这时没有画面可留，
    /// 暂停也拦不住随后加载完成的自动起播。
    let pauseKeepingPicture: () -> Bool
    /// 活视频此刻是否在播放（含等待缓冲）；被盖住时据此记下“是不是盖住暂停的”。
    let isPlaying: () -> Bool
    /// 继续播放活视频；回到被盖住、由盖住暂停的视频时调用。
    let resume: () -> Void
    /// 呈现中视频此刻的秒数；没有呈现中的视频时为 nil。
    ///
    /// 被盖住暂停时记下，回来时据此判断用户被盖住期间动过没有。
    let presentedPosition: () -> Double?
    /// 活视频此刻的分 P 与秒数，写成重建用的选择意图；没有呈现中的视频时为 nil。
    let resumePoint: () -> PlaybackSelectionIntent?
    /// 把呈现中的视频写成「刚才看过」的一项（标题、封面等取自视频模型）；呈现的已不是这个 BVID 时为 nil。
    let recentlyWatchedEntry: (PlaybackSelectionIntent) -> RecentlyWatchedVideo?
    /// 画中画是否进行中；被盖住时画中画里的视频继续播放，不暂停。
    let isPictureInPictureActive: () -> Bool
}

/// 活视频被盖住时由我们暂停的记录：暂停时的秒数（拿不到时为 nil）。
private struct CoveredPause {
    let position: Double?
}

/// 协调窗口内的顶层 Tab、右侧历史、播放生命周期副作用与侧栏上下文层。
///
/// 拥有右侧的历史栈（`history`，栈顶决定显示什么，空栈是来源根页）、活视频绑定在哪一项（`liveEntryID`）、整页空间模型
/// 属于哪一项（`liveSpaceEntryID`）与一次延后的停止；不拥有播放器（经 `AppPlaybackSession`）与转场（经 `transitionPage`）。
/// 压一层、原地替换、盖住与恢复的规则见 docs/ARCHITECTURE.md「动线与侧栏上下文层」。侧栏类别、侧栏宽度、右侧页面与评论
/// 图片预览看栈顶，评论激活看活视频。切换来源、登出与关窗经 `closePlayback()` 清空历史并立即停止。侧栏上下文层（UP 主
/// 空间预览）的打开与关闭入口都在这里，是否打开从预览模型的 `owner` 派生；它自己在返回按钮或账户会话切换时关闭，同样
/// 反映到 `isSidebarContextOpen`。
@MainActor
@Observable
final class AppNavigationCoordinator {
    var selectedTab: AppTab = .home {
        didSet {
            guard selectedTab != oldValue else { return }
            closePlayback()
        }
    }
    /// 右侧历史，栈顶在末尾；空时在来源根页。
    ///
    /// 栈一空就清空「刚才看过」：它只属于这一段历史，不论经哪条路回到来源根页（⌂、一路「返回」、换来源、登出、关窗）
    /// 都一起结束。各个回根页的入口因此不各自清空，新增入口也不会漏。
    private(set) var history: [AppHistoryEntry] = [] {
        didSet {
            if history.isEmpty, !recentlyWatched.isEmpty { recentlyWatched.removeAll() }
        }
    }
    /// 「刚才看过」：这一段历史里离开过的视频（被另一个视频取代，或经「返回」离开），最近离开的在前，按 BVID 去重，
    /// 不含正在播放的这个。
    ///
    /// 只在内存里，生命周期与历史栈相同（见 `history`）。
    private(set) var recentlyWatched: [RecentlyWatchedVideo] = []
    /// 「刚才看过」最多留几项；横排一屏放五六张，留多了只是往后翻不到的旧记录。
    private static let recentlyWatchedLimit = 20
    var topDestination: AppDestination? {
        history.last?.destination
    }
    var canGoBack: Bool {
        !history.isEmpty
    }
    /// 栈顶的播放页；栈顶不是播放页时为 nil。
    var currentPlaybackIntent: PlaybackSelectionIntent? {
        guard case .playback(let intent) = history.last?.destination else { return nil }
        return intent
    }
    var currentPlaybackBVID: String? {
        currentPlaybackIntent?.bvid
    }
    /// 活视频：此刻载入播放器的视频；它所在的项可能是栈顶，也可能被盖住。
    var livePlaybackBVID: String? {
        liveIntent?.bvid
    }
    /// 侧栏上下文层（UP 主空间预览）的内容模型；每个窗口都有，空间入口与空间链接都在这里打开。
    @ObservationIgnored let uploaderSpace: UploaderSpaceViewModel
    /// 整页空间页的内容模型，属于最上面的空间项。
    @ObservationIgnored let uploaderSpacePage: UploaderSpaceViewModel
    /// 此刻占用整页空间模型的空间项；没有时为 nil。
    ///
    /// 视图按它区分网格保活与滚动位置。
    private(set) var liveSpaceEntryID: UInt64?
    /// 上下文层是否打开：底层要隐藏、侧栏要叠上空间列表。
    var isSidebarContextOpen: Bool {
        uploaderSpace.owner != nil
    }

    private var liveIntent: PlaybackSelectionIntent?
    /// 活视频所在的历史项；没有活视频时为 nil。
    @ObservationIgnored private var liveEntryID: UInt64?
    /// 活视频被空间页盖住时由我们暂停的，记下暂停时的秒数；回到它时只恢复这种，用户自己暂停或已播完的保持不动。
    ///
    /// 被盖住期间用户仍能经媒体键、控制中心播放、暂停或拖动（照常播放）；回来时位置与记下的相差超过
    /// `coveredPositionTolerance`，说明用户动过，按用户此刻的状态保持不动。nil 表示没有要恢复的。
    @ObservationIgnored private var pausedByCovering: CoveredPause?
    /// 判断被盖住期间用户动过没有的位置容差（秒）。
    ///
    /// 盖住暂停后周期观察可能再报一次略晚的位置；用户被盖住期间播放或拖动造成的位移远大于这个值。调大会把短暂的播放
    /// 当成没动过，调小会把暂停后迟到的位置当成用户动过。
    private static let coveredPositionTolerance = 0.5
    /// 下一个压入的历史项的 id；只增不减。
    @ObservationIgnored private var nextEntryID: UInt64 = 0
    /// 返回时延后的停止是否还没执行。
    @ObservationIgnored private var hasPendingStop = false
    /// 延后停止的代次：每次发出延后停止与提前完成它时递增；转场结束的回调只在代次未变时停止，否则说明这次停止已被
    /// 提前完成（又进了播放页、换来源、登出或关窗），丢弃回调，不会停掉之后的播放。
    @ObservationIgnored private var pendingStopGeneration: UInt64 = 0
    @ObservationIgnored private let playback: AppPlaybackSession
    @ObservationIgnored private let transitionPage:
        (AppPageTransition, _ change: () -> Void, _ completion: @escaping () -> Void) -> Void
    @ObservationIgnored private let transitionSidebarContext:
        (AppPageTransition, _ change: () -> Void) -> Void

    /// - Parameters:
    ///   - playback: 开始、暂停与停止播放。
    ///   - transitionPage: 进出页面的转场。必须同步调用 `change` 恰好一次，转场结束（或没有转场）后调用 `completion`
    ///     恰好一次；`completion` 可以晚于本次调用。
    ///   - transitionSidebarContext: 侧栏上下文层打开（`.push`）与用户关闭（`.pop`）的转场。必须同步调用 `change` 恰好一次。
    ///   - uploaderSpace: 侧栏上下文层（UP 主空间预览）的模型。上下文层只在播放页上存在，离开播放页、或从
    ///     上下文层以外的入口换视频时关闭它。
    ///   - uploaderSpacePage: 整页空间页的模型。
    init(
        playback: AppPlaybackSession,
        transitionPage:
            @escaping (
                AppPageTransition, _ change: () -> Void, _ completion: @escaping () -> Void
            ) -> Void,
        transitionSidebarContext: @escaping (AppPageTransition, _ change: () -> Void) -> Void,
        uploaderSpace: UploaderSpaceViewModel,
        uploaderSpacePage: UploaderSpaceViewModel
    ) {
        self.playback = playback
        self.transitionPage = transitionPage
        self.transitionSidebarContext = transitionSidebarContext
        self.uploaderSpace = uploaderSpace
        self.uploaderSpacePage = uploaderSpacePage
    }

    /// 在侧栏上下文层打开某位 UP 主的空间（播放侧栏的 UP 主行、评论作者与 @ 提及）。
    func openUploaderSpace(owner: VideoOwner) {
        openSidebarContext { uploaderSpace.open(owner: owner) }
    }

    /// 只有 MID 的入口（评论正文里的空间链接）：先以 UID 作头部打开，名片到达后补上名字与头像。
    func openUploaderSpace(ownerID: Int64) {
        openSidebarContext { uploaderSpace.open(ownerID: ownerID) }
    }

    /// 上下文层已开着时原地换人，不再推一次。
    private func openSidebarContext(_ open: () -> Void) {
        if isSidebarContextOpen {
            open()
        } else {
            transitionSidebarContext(.push, open)
        }
    }

    /// 用户关掉上下文层（预览的返回按钮、⌘[、从上下文层以外换视频）：侧栏把原来的内容推回来。
    ///
    /// 换页的同时关闭（压一层、返回、回首页、换来源、登出、关窗）不走这里：换页转场已经让侧栏淡入淡出，不再叠一次推。
    func dismissSidebarContext() {
        guard isSidebarContextOpen else { return }
        transitionSidebarContext(.pop) { closeSidebarContext() }
    }

    /// 打开某位 UP 主的整页空间页（预览里的「打开完整空间」）：栈顶已是空间页时原地换人，否则压一层；被盖住的活视频
    /// 暂停，还在加载的直接停止。
    ///
    /// 原地换人那一支守住“同类页面不相邻”：预览只在播放页上打开，界面上不会从空间页走到这里。
    func openUploaderSpacePage(owner: VideoOwner) {
        closeSidebarContext()
        let destination = UploaderSpaceDestination(owner: owner, order: .newest, searchKeyword: nil)
        if let top = history.last, case .uploaderSpace(let current) = top.destination {
            guard current.owner.id != owner.id else { return }
            history[history.count - 1].destination = .uploaderSpace(destination)
            showSpace(destination, entryID: top.id)
            return
        }
        completePendingStop()
        coverLivePlayback()
        let entry = AppHistoryEntry(id: takeEntryID(), destination: .uploaderSpace(destination))
        pushPage(entry)
        showSpace(destination, entryID: entry.id)
    }

    /// 整页空间模型被认证会话切换关掉、而栈顶仍是它时（会话切换通常会清空历史，这里兜底），按栈顶那一项重新打开。
    func restoreTopSpaceIfClosed() {
        guard uploaderSpacePage.owner == nil,
            let top = history.last,
            case .uploaderSpace(let destination) = top.destination
        else { return }
        showSpace(destination, entryID: top.id)
    }

    /// 栈顶不是播放页时压一层播放页；栈顶是播放页时只替换它的媒体 identity。
    func openPlayback(_ bvid: String) {
        openPlayback(PlaybackSelectionIntent(bvid: bvid))
    }

    /// 播放页侧栏的选分 P、选集：在当前视频里换分 P，或换到合集里的另一集；离开侧栏上下文层。
    func openPlayback(_ bvid: String, preferredCID: Int64?) {
        openPlayback(PlaybackSelectionIntent(bvid: bvid, preferredCID: preferredCID))
    }

    /// 播完后的自动连播与列表循环：与侧栏选分 P、选集同一意图，但不是用户从别处换视频，侧栏上下文层保留。
    ///
    /// 只在栈顶就是活视频那一项时生效：下一集要先解析，解析回来之前用户已经离开（返回中、被盖住或回到根页）时，
    /// 不把用户拉回播放页，也不在看不见的地方换片起播。
    func continuePlayback(_ bvid: String, preferredCID: Int64?) {
        guard let top = history.last, top.id == liveEntryID else { return }
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
            dismissSidebarContext()
        }
        if let top = history.last, case .playback(let current) = top.destination {
            guard current != intent else { return }
            rememberRecentlyWatched(replacingWith: intent.bvid)
            rememberResumePoint(excluding: top.id)
            history[history.count - 1].destination = .playback(intent)
            makeLive(intent, entryID: top.id)
            return
        }
        // 返回的转场还没结束就又进了播放页：先完成上一次停止，与立即停止后再开始一样，不让旧视频的停止晚到。
        completePendingStop()
        captureSpaceState()
        if let live = liveIntent, live.bvid == intent.bvid {
            // 被盖住的就是这个视频（空间页里又点了它）：活视频改绑到新压的这一项，不重新起播；意图明确指向另一个分 P
            // 时按换分 P 处理（视频模型在已有分 P 里切换）。
            let switchesPage =
                intent.preferredCID != nil && intent.preferredCID != live.preferredCID
            let entry = AppHistoryEntry(
                id: takeEntryID(),
                destination: .playback(switchesPage ? intent : live)
            )
            pushPage(entry)
            if switchesPage {
                makeLive(intent, entryID: entry.id)
            } else {
                liveEntryID = entry.id
                resumeIfPausedByCovering()
            }
            return
        }
        rememberRecentlyWatched(replacingWith: intent.bvid)
        rememberResumePoint(excluding: nil)
        let entry = AppHistoryEntry(id: takeEntryID(), destination: .playback(intent))
        pushPage(entry)
        makeLive(intent, entryID: entry.id)
    }

    func retryPlayback() {
        guard let intent = currentPlaybackIntent else { return }
        playback.start(intent)
    }

    /// 工具栏「返回」：弹出栈顶一页，按新的栈顶恢复；在根页时不动作，所以连点只停止一次。
    ///
    /// - 回到播放页：是被盖住的活视频就接着它（只恢复盖住暂停的）；不是就按这一项记下的意图重建。
    /// - 离开活视频所在的播放页、回到空间页：下面最近的播放项是同一个视频时按被盖住处理，活视频改绑过去；否则先暂停、
    ///   转场结束后再停止（停止播放会立即清空画面，放在换页的同一次提交里时，旧页面带着黑掉的视频区离开）。
    /// - 回到根页：同上，先暂停、转场后停止；还没有画面可留时照样转场，但立即停止。
    func goBack() {
        guard let top = history.last else { return }
        let newTop = history.dropLast().last
        let change = {
            self.history.removeLast()
            self.closeSidebarContext()
        }
        switch newTop?.destination {
        case .playback(let intent)?:
            completePendingStop()
            popPage(change)
            closeSpacePageIfUnused()
            guard let newTop else { return }
            if newTop.id == liveEntryID {
                resumeIfPausedByCovering()
            } else {
                stopLivePlayback()
                makeLive(intent, entryID: newTop.id)
            }
        case .uploaderSpace(let destination)?:
            guard let newTop else { return }
            if top.id == liveEntryID, let lower = nearestPlaybackEntry(below: newTop.id),
                case .playback(let lowerIntent) = lower.destination,
                lowerIntent.bvid == liveIntent?.bvid
            {
                if let liveIntent {
                    history[historyIndex(of: lower.id)].destination = .playback(liveIntent)
                }
                liveEntryID = lower.id
                popPage(change)
                coverLivePlayback()
            } else if top.id == liveEntryID {
                popStoppingLivePlayback(change)
            } else {
                popPage(change)
            }
            // 模型被会话切换关掉时，即使仍属于这一项也重新打开，否则回来只看到骨架屏。
            if liveSpaceEntryID != newTop.id || uploaderSpacePage.owner == nil {
                showSpace(destination, entryID: newTop.id)
            }
        case nil:
            if top.id == liveEntryID {
                popStoppingLivePlayback(change)
            } else {
                rememberRecentlyWatched(replacingWith: nil)
                popPage(change)
                stopLivePlayback()
            }
            closeSpacePageIfUnused()
        }
    }

    /// 「前往 › 返回」（⌘[）：侧栏的 UP 主空间预览开着时先关预览（与预览自己的返回按钮一样），否则同工具栏「返回」。
    func navigateBack() {
        if isSidebarContextOpen {
            dismissSidebarContext()
        } else {
            goBack()
        }
    }

    /// 「前往 › 返回」此刻能否动作。
    var canNavigateBack: Bool {
        isSidebarContextOpen || canGoBack
    }

    /// 工具栏 ⌂：清空历史回到来源根页并停止播放。
    ///
    /// 栈顶就是活视频时先暂停、转场后停止（旧页面带着画面离开）；栈顶是空间页时没有画面可留，立即停止。
    func goHome() {
        guard let top = history.last else { return }
        let change = {
            self.history.removeAll()
            self.closeSidebarContext()
        }
        if top.id == liveEntryID {
            popStoppingLivePlayback(change)
        } else {
            popPage(change)
            stopLivePlayback()
        }
        closeSpacePageIfUnused()
    }

    /// 侧栏选了另一个来源或同一来源里的另一行（另一个收藏夹）：清空历史并停止播放，回到那个来源的根页。
    ///
    /// 换来源本来由 `selectedTab` 的变化收口；同一来源里换行不改 `selectedTab`，由侧栏的选择入口显式调用。
    func closeForSidebarSelection() {
        closePlayback()
    }

    /// 画中画「还原」：弹掉盖在活视频播放页上面的层，回到它；返回是否能还原（没有活视频时不能）。
    ///
    /// 画中画里的视频一直在播放，回到播放页时不再继续或暂停。
    func restoreLivePlaybackPage() -> Bool {
        guard let liveEntryID, let index = history.firstIndex(where: { $0.id == liveEntryID })
        else {
            return false
        }
        pausedByCovering = nil
        guard index < history.count - 1 else { return true }
        popPage {
            history.removeSubrange((index + 1)...)
            closeSidebarContext()
        }
        closeSpacePageIfUnused()
        return true
    }

    /// 画中画结束、但不是「还原」（用户点了关闭）：活视频被盖住时已没有可见的播放器，按被盖住处理（在播放的暂停，
    /// 还在加载的停止）；在播放页上时不动作。
    func pictureInPictureDidStopWithoutRestore() {
        guard liveEntryID != nil, history.last?.id != liveEntryID else { return }
        coverLivePlayback()
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

    /// 清空历史并立即停止活视频。
    private func closePlayback() {
        completePendingStop()
        guard !history.isEmpty || liveIntent != nil else { return }
        history.removeAll()
        closeSidebarContext()
        closeSpacePageIfUnused()
        stopLivePlayback()
    }

    private func makeLive(_ intent: PlaybackSelectionIntent, entryID: UInt64) {
        liveIntent = intent
        liveEntryID = entryID
        pausedByCovering = nil
        playback.start(intent)
    }

    private func clearLive() {
        liveIntent = nil
        liveEntryID = nil
        pausedByCovering = nil
    }

    /// 立即停止活视频；没有活视频时不动作。
    private func stopLivePlayback() {
        guard liveIntent != nil else { return }
        clearLive()
        playback.stop()
    }

    /// 活视频所在的播放页被异类页面盖住：画中画中的继续播放；在播放的暂停并记下；还在加载（没有画面、暂停拦不住随后的
    /// 自动起播）的直接停止，它那一项保留原来的意图，回来时重新加载。
    private func coverLivePlayback() {
        guard liveIntent != nil else { return }
        guard !playback.isPictureInPictureActive() else {
            pausedByCovering = nil
            return
        }
        let wasPlaying = playback.isPlaying()
        guard playback.pauseKeepingPicture() else {
            stopLivePlayback()
            return
        }
        pausedByCovering = wasPlaying ? CoveredPause(position: playback.presentedPosition()) : nil
    }

    private func resumeIfPausedByCovering() {
        guard let pause = pausedByCovering else { return }
        pausedByCovering = nil
        if let paused = pause.position, let current = playback.presentedPosition(),
            abs(current - paused) > Self.coveredPositionTolerance
        {
            return
        }
        playback.resume()
    }

    /// 活视频要被 `newBVID` 取代，或经「返回」离开（`newBVID` 为 nil）时记进「刚才看过」。
    ///
    /// 换的是另一个视频时把活视频此刻的位置记在最前，新视频自己移出列表；必须在清掉活视频之前调用。
    private func rememberRecentlyWatched(replacingWith newBVID: String?) {
        if let newBVID { recentlyWatched.removeAll { $0.id == newBVID } }
        guard let live = liveIntent, live.bvid != newBVID else { return }
        // 还没开始播放就切走时没有播放位置，按离开的分 P 从头记；详情也还没到时记不了，跳过。
        let point =
            playback.resumePoint().flatMap { $0.bvid == live.bvid ? $0 : nil }
            ?? PlaybackSelectionIntent(bvid: live.bvid, preferredCID: live.preferredCID)
        guard let entry = playback.recentlyWatchedEntry(point) else { return }
        recentlyWatched.removeAll { $0.id == entry.id }
        recentlyWatched.insert(entry, at: 0)
        if recentlyWatched.count > Self.recentlyWatchedLimit {
            recentlyWatched.removeLast(recentlyWatched.count - Self.recentlyWatchedLimit)
        }
    }

    /// 活视频要被新视频取代：把它此刻的分 P 与秒数写回历史里同一视频最近的播放项（`excluding` 是正被原地替换的那一项），
    /// 回去时从这里重建。
    private func rememberResumePoint(excluding excludedID: UInt64?) {
        guard let live = liveIntent, let point = playback.resumePoint(), point.bvid == live.bvid
        else { return }
        guard
            let index = history.lastIndex(where: { entry in
                guard entry.id != excludedID, case .playback(let intent) = entry.destination else {
                    return false
                }
                return intent.bvid == live.bvid
            })
        else { return }
        history[index].destination = .playback(point)
    }

    private func nearestPlaybackEntry(below entryID: UInt64) -> AppHistoryEntry? {
        let index = historyIndex(of: entryID)
        return history[..<index].last { entry in
            if case .playback = entry.destination { return true }
            return false
        }
    }

    private func historyIndex(of entryID: UInt64) -> Int {
        history.firstIndex { $0.id == entryID } ?? history.count
    }

    /// 让整页空间模型显示这一项：先把它当前的排序与搜索词写回原来占用它的那一项，再按这一项的条件从第一批重建。
    ///
    /// 模型仍属于这一项时（原地换人、关掉后重开）不写回：那一项已经是新的条件，模型里的是旧人或已关闭的默认值。
    private func showSpace(_ destination: UploaderSpaceDestination, entryID: UInt64) {
        if liveSpaceEntryID != entryID { captureSpaceState() }
        uploaderSpacePage.open(
            owner: destination.owner,
            order: destination.order,
            searchKeyword: destination.searchKeyword
        )
        liveSpaceEntryID = entryID
    }

    /// 把整页空间模型此刻的排序与搜索词写回占用它的那一项；那一项已不在历史里时不动作。
    private func captureSpaceState() {
        guard let liveSpaceEntryID,
            let index = history.firstIndex(where: { $0.id == liveSpaceEntryID }),
            case .uploaderSpace(var destination) = history[index].destination
        else { return }
        destination.order = uploaderSpacePage.order
        destination.searchKeyword = uploaderSpacePage.searchKeyword
        history[index].destination = .uploaderSpace(destination)
    }

    /// 占用整页空间模型的那一项已不在历史里（被弹出或清空）时关闭模型，放开投稿；外壳随 `liveSpaceEntryID` 变为 nil
    /// 丢弃保活里的那份网格。
    private func closeSpacePageIfUnused() {
        guard let liveSpaceEntryID, !history.contains(where: { $0.id == liveSpaceEntryID })
        else { return }
        self.liveSpaceEntryID = nil
        uploaderSpacePage.close()
    }

    private func takeEntryID() -> UInt64 {
        nextEntryID &+= 1
        return nextEntryID
    }

    /// 离开活视频所在的页面：有画面可留时先暂停，转场结束后再停止；没有时转场照常、立即停止。
    private func popStoppingLivePlayback(_ change: () -> Void) {
        guard liveIntent != nil else {
            popPage(change)
            return
        }
        // 经「返回」离开的视频历史里已经没有它那一项，只剩「刚才看过」能回去；回到的是来源根页时，它随历史一起清空。
        rememberRecentlyWatched(replacingWith: nil)
        clearLive()
        guard playback.pauseKeepingPicture() else {
            popPage(change)
            playback.stop()
            return
        }
        hasPendingStop = true
        pendingStopGeneration &+= 1
        let generation = pendingStopGeneration
        popPage(change) { [weak self] in
            guard let self, self.hasPendingStop, self.pendingStopGeneration == generation else {
                return
            }
            self.hasPendingStop = false
            self.playback.stop()
        }
    }

    /// 压一层的转场：移动的是压进来的这一页。
    private func pushPage(_ entry: AppHistoryEntry) {
        transitionPage(.push, { history.append(entry) }, {})
    }

    /// 弹出的转场：`change` 弹掉栈顶，转场结束（或没有转场）后调用 `completion`。
    private func popPage(_ change: () -> Void, completion: @escaping () -> Void = {}) {
        transitionPage(.pop, change, completion)
    }

    /// 提前完成返回时延后的停止；没有延后的停止时不动作。
    private func completePendingStop() {
        guard hasPendingStop else { return }
        hasPendingStop = false
        pendingStopGeneration &+= 1
        playback.stop()
    }

    private func closeSidebarContext() {
        uploaderSpace.close()
    }
}
