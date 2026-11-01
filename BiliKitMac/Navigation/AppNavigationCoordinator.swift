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

/// 播放层在 `NavigationStack` 路径里的唯一元素，只标识播放 surface，不携带视频。
///
/// 右侧栈深最多 1（见 docs/ARCHITECTURE.md「动线与右栏上下文层」）：首次打开播放时生成
/// `surfaceID`，之后换视频只替换 `ActivePlayback.intent`，surface 不变，导航路径不因换视频而变化。
struct PlaybackDestination: Hashable {
    let surfaceID: UUID
}

/// 当前播放层：建立后不变的 surface 与可替换的选择意图；为 nil 表示不在播放层。
private struct ActivePlayback: Equatable {
    let destination: PlaybackDestination
    var intent: PlaybackSelectionIntent
}

/// 协调窗口内的顶层 Tab、原生导航路径、播放生命周期副作用与右栏上下文层。
///
/// Coordinator 不拥有播放器：开始与停止播放经 `WindowComposition` 注入的闭包交给视频与弹幕模型。
/// typed path 只表达是否位于播放层级，当前 BVID 则表达该层级内的媒体 identity。系统返回、切换来源、
/// 登出与关窗都经 `closePlayback()` 这一条播放副作用边界收口。右栏上下文层（UP 主空间）
/// 的打开与关闭入口都在这里，是否打开从空间模型的 `owner` 派生；
/// 空间模型自己在返回按钮或账户会话切换时关闭，同样反映到 `isContextLayerOpen`。
@MainActor
@Observable
final class AppNavigationCoordinator {
    var selectedTab: AppTab = .home {
        didSet {
            guard selectedTab != oldValue else { return }
            closePlayback()
        }
    }
    var playbackPath: [PlaybackDestination] {
        get {
            activePlayback.map { [$0.destination] } ?? []
        }
        set {
            // 只有 openPlayback 可以建立播放 surface；系统 path 写回只负责 pop。
            guard newValue.isEmpty else { return }
            closePlayback()
        }
    }
    var currentPlaybackBVID: String? {
        activePlayback?.intent.bvid
    }
    var currentPlaybackIntent: PlaybackSelectionIntent? {
        activePlayback?.intent
    }
    /// 右栏上下文层的内容模型；每个窗口都有，空间入口与空间链接都在这里打开。
    @ObservationIgnored let uploaderSpace: UploaderSpaceViewModel
    /// 上下文层是否打开：右栏的相关推荐要隐藏、叠上空间列表。
    var isContextLayerOpen: Bool {
        uploaderSpace.owner != nil
    }

    private var activePlayback: ActivePlayback?
    @ObservationIgnored private let startPlayback: (PlaybackSelectionIntent) -> Void
    @ObservationIgnored private let stopPlayback: () -> Void

    /// - Parameters:
    ///   - startPlayback: 开始或替换当前视频。
    ///   - stopPlayback: 关闭播放后停止播放器与弹幕。
    ///   - uploaderSpace: 右栏上下文层（UP 主空间）的模型。上下文层只在播放时存在，关闭播放、或从
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

    /// 在右栏上下文层打开某位 UP 主的空间（详情区的 UP 主行、评论作者与 @ 提及）。
    func openUploaderSpace(owner: VideoOwner) {
        uploaderSpace.open(owner: owner)
    }

    /// 只有 MID 的入口（评论正文里的空间链接）：先以 UID 作头部打开，名片到达后补上名字与头像。
    func openUploaderSpace(ownerID: Int64) {
        uploaderSpace.open(ownerID: ownerID)
    }

    /// 首次打开建立播放 surface；连续打开其他视频只替换媒体 identity。
    func openPlayback(_ bvid: String) {
        openPlayback(PlaybackSelectionIntent(bvid: bvid))
    }

    /// 播放页详情区的选分 P、选集：在当前视频里换分 P，或换到合集里的另一集；离开右栏上下文层。
    func openPlayback(_ bvid: String, preferredCID: Int64?) {
        openPlayback(PlaybackSelectionIntent(bvid: bvid, preferredCID: preferredCID))
    }

    /// 播完后的自动连播与列表循环：与详情区选分 P、选集同一意图，但不是用户从别处换视频，右栏上下文层保留。
    func continuePlayback(_ bvid: String, preferredCID: Int64?) {
        openPlayback(
            PlaybackSelectionIntent(bvid: bvid, preferredCID: preferredCID),
            preservesContextLayer: true
        )
    }

    /// 从右栏上下文层（UP 主空间）里选择视频：用户仍在逛这个空间，上下文层保留。
    func openPlaybackFromContextLayer(_ bvid: String) {
        openPlayback(PlaybackSelectionIntent(bvid: bvid), preservesContextLayer: true)
    }

    /// 来源页、相关推荐、选集、评论链接等入口换视频：用户已离开上下文层，关闭它退回详情。
    ///
    /// 按“从哪里打开”判断，不比较新视频的 UP 主：联合投稿的 UP 主字段可能是另一位。
    /// 重新点击正在播放的视频同样算离开上下文层。
    func openPlayback(_ intent: PlaybackSelectionIntent) {
        openPlayback(intent, preservesContextLayer: false)
    }

    /// 建立播放 surface 即压栈播放页；调用方不得放进 `withAnimation`，否则来源网格会一直挂在播放页下面绘制
    /// （见 ARCHITECTURE「播放页布局」）。
    private func openPlayback(
        _ intent: PlaybackSelectionIntent,
        preservesContextLayer: Bool
    ) {
        guard !intent.bvid.isEmpty else { return }
        if !preservesContextLayer {
            closeContextLayer()
        }
        guard currentPlaybackIntent != intent else { return }

        if var activePlayback {
            activePlayback.intent = intent
            self.activePlayback = activePlayback
        } else {
            activePlayback = ActivePlayback(
                destination: PlaybackDestination(surfaceID: UUID()),
                intent: intent
            )
        }
        startPlayback(intent)
    }

    func retryPlayback() {
        guard let intent = currentPlaybackIntent else { return }
        startPlayback(intent)
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
        closeContextLayer()
        stopPlayback()
    }

    private func closeContextLayer() {
        uploaderSpace.close()
    }
}
