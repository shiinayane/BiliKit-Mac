import AVKit
import BiliApplication
import BiliDanmaku
import BiliModels
import BiliPlayback
import BiliVideoCollectionUI
import BiliVideoDetailFeature
import SwiftUI

/// 把唯一 `AVPlayer` 宿主与弹幕 overlay 组合为稳定的播放 surface。
///
/// 响应式页面可以重排这个 View，但不应创建第二个 player host：AppKit 宿主归窗口的 `PlayerHostOwner`，这个 View
/// 卸载时宿主只被摘下，关窗时才断开 player 并释放弹幕 surface ownership。
struct PlayerHostView: View {
    @State private var previewEndedNotice: String?
    let player: SeekTrackingPlayer
    let danmakuRenderer: CoreAnimationDanmakuRenderer
    let danmakuController: DanmakuPresentationController
    let videoModel: VideoViewModel?
    let beginMomentaryPlaybackRate: ((Float) -> UUID?)?
    let endMomentaryPlaybackRate: ((UUID) -> Void)?
    let seekByTransportOffset: ((Double) -> Bool)?
    let adjustVolume: ((Float) -> Float)?
    let togglePlayback: (() -> Bool?)?
    let toggleDanmaku: (() -> Bool)?
    let toggleSubtitles: (() async -> NativeSubtitleToggleResult)?
    let engagementShortcuts: PlayerEngagementShortcuts?
    /// 回车呼出的发送弹幕输入胶囊；为 nil 时回车不响应。
    let danmakuComposer: DanmakuComposerModel?
    /// 点击弹幕关联视频卡片时在应用内打开该视频（参数是 BV 号）；为 nil 时卡片不接点击。
    let openDanmakuLinkedVideo: ((String) -> Void)?
    let actionMenu: PlayerActionMenuActions
    let playbackEnd: PlayerPlaybackEndActions
    /// 订阅章节模型的「进入第几章」提示（`VideoChapterModel.observeAnnouncements`）。
    let chapterAnnouncements: NativePlayerHostView.ChapterAnnouncementObserving
    let timelineUpdates: (() -> AsyncStream<PlaybackTimelineSnapshot>)?
    /// 登记宿主视图，供加载时按播放器所在屏幕判断 HDR。
    let hdrEnvironment: PlaybackHDREnvironment
    /// 窗口常驻的宿主；见 `PlayerHostOwner`。
    let hostOwner: PlayerHostOwner

    init(
        player: SeekTrackingPlayer,
        danmakuRenderer: CoreAnimationDanmakuRenderer,
        danmakuController: DanmakuPresentationController,
        videoModel: VideoViewModel? = nil,
        beginMomentaryPlaybackRate: ((Float) -> UUID?)? = nil,
        endMomentaryPlaybackRate: ((UUID) -> Void)? = nil,
        seekByTransportOffset: ((Double) -> Bool)? = nil,
        adjustVolume: ((Float) -> Float)? = nil,
        togglePlayback: (() -> Bool?)? = nil,
        toggleDanmaku: (() -> Bool)? = nil,
        toggleSubtitles: (() async -> NativeSubtitleToggleResult)? = nil,
        engagementShortcuts: PlayerEngagementShortcuts? = nil,
        danmakuComposer: DanmakuComposerModel? = nil,
        openDanmakuLinkedVideo: ((String) -> Void)? = nil,
        actionMenu: PlayerActionMenuActions,
        playbackEnd: PlayerPlaybackEndActions,
        chapterAnnouncements: @escaping NativePlayerHostView.ChapterAnnouncementObserving,
        timelineUpdates: (() -> AsyncStream<PlaybackTimelineSnapshot>)? = nil,
        hdrEnvironment: PlaybackHDREnvironment,
        hostOwner: PlayerHostOwner
    ) {
        self.player = player
        self.danmakuRenderer = danmakuRenderer
        self.danmakuController = danmakuController
        self.videoModel = videoModel
        self.beginMomentaryPlaybackRate = beginMomentaryPlaybackRate
        self.endMomentaryPlaybackRate = endMomentaryPlaybackRate
        self.seekByTransportOffset = seekByTransportOffset
        self.adjustVolume = adjustVolume
        self.togglePlayback = togglePlayback
        self.toggleDanmaku = toggleDanmaku
        self.toggleSubtitles = toggleSubtitles
        self.engagementShortcuts = engagementShortcuts
        self.danmakuComposer = danmakuComposer
        self.openDanmakuLinkedVideo = openDanmakuLinkedVideo
        self.actionMenu = actionMenu
        self.playbackEnd = playbackEnd
        self.chapterAnnouncements = chapterAnnouncements
        self.timelineUpdates = timelineUpdates
        self.hdrEnvironment = hdrEnvironment
        self.hostOwner = hostOwner
    }

    var body: some View {
        AVPlayerContainerView(
            player: player,
            renderer: danmakuRenderer,
            controller: danmakuController,
            blocksNativePlaybackInteraction: blocksNativePlaybackInteraction,
            resumeNotice: videoModel?.resumeNotice,
            previewEndedNotice: previewEndedNotice,
            restartFromBeginning: { videoModel?.restartFromBeginning() },
            beginMomentaryPlaybackRate: beginMomentaryPlaybackRate,
            endMomentaryPlaybackRate: endMomentaryPlaybackRate,
            seekByTransportOffset: seekByTransportOffset,
            adjustVolume: adjustVolume,
            togglePlayback: togglePlayback,
            toggleDanmaku: toggleDanmaku,
            toggleSubtitles: toggleSubtitles,
            engagementShortcuts: engagementShortcuts,
            danmakuComposer: danmakuComposer,
            openDanmakuLinkedVideo: openDanmakuLinkedVideo,
            actionMenu: actionMenu,
            playbackEnd: playbackEnd,
            chapterAnnouncements: chapterAnnouncements,
            focusIdentity: videoModel?.presentedBVID,
            hdrEnvironment: hdrEnvironment,
            hostOwner: hostOwner
        )
        .task(id: previewProjectionIdentity) {
            previewEndedNotice = nil
            // 只有充电试看会出现这条提示，其他视频不订阅时间线：时间线按媒体时间刷新（倍速时更频繁），每次写入
            // 都会让整个播放器区域重新求值一次。
            guard let timelineUpdates,
                let context = videoModel?.presentedContext,
                PlaybackPreviewEndPolicy.canPresentNotice(for: context.accessNotice)
            else { return }
            let identity = PlaybackItemIdentity(
                bvid: context.detail.bvid,
                cid: context.selectedPage.cid
            )
            for await snapshot in timelineUpdates() {
                guard !Task.isCancelled else { return }
                let notice =
                    PlaybackPreviewEndPolicy.shouldPresentNotice(
                        accessNotice: context.accessNotice,
                        expectedIdentity: identity,
                        timeline: snapshot
                    )
                    ? AppStrings.localized(
                        "试看已结束，此视频为充电专属，BiliKit 暂不提供充电操作。"
                    ) : nil
                // 只在提示真的变化时写入，不让每个时间线刷新都触发一次重新求值。
                if previewEndedNotice != notice { previewEndedNotice = notice }
            }
        }
    }

    private var blocksNativePlaybackInteraction: Bool {
        guard let videoModel else { return false }
        return switch videoModel.state {
        case .loading, .loadingPage, .preparingPlayback:
            true
        case .idle, .ready, .failed, .failedPage:
            false
        }
    }

    private var previewProjectionIdentity: String? {
        guard let context = videoModel?.presentedContext else { return nil }
        return
            "\(context.detail.bvid):\(context.selectedPage.cid):\(String(describing: context.accessNotice))"
    }
}

/// 唯一的播放器 AppKit 宿主：`AVPlayerView` 子类，在 content overlay 上挂弹幕层与 SwiftUI
/// 提示浮层。
///
/// 用 AppKit：原生控制条、画中画与全屏都来自 `AVPlayerView`，弹幕与浮层要放进它的 content overlay
/// 才能随 detached 全屏一起移动，见 docs/ARCHITECTURE.md「播放页布局」。拥有键盘快捷键
/// controller（本地 key monitor）、浮层模型、player 的三个 KVO 观察与在途 seek 通知观察、当前 item 的
/// 两个 KVO 观察与时间跳转观察、失焦通知观察，以及章节提示的订阅（挂上播放页时订阅，摘下与拆除时取消）；不拥有
/// player、弹幕 renderer、弹幕 controller 与章节模型，它们由窗口组装持有。
/// 宿主随窗口常驻（owner 是 `PlayerHostOwner`）：播放页挂上与摘下时由 `AVPlayerContainerView` 调用
/// `mountInPage(playbackEnd:chapterAnnouncements:)` 与 `unmountFromPage()`，只开关逐页的观察与提示，player 与弹幕绑定
/// 不动；拆除经
/// `tearDown()`，见它的说明。`currentItem` 变化时先让弹幕 overlay 换绑时钟（见 `DanmakuOverlayView.bind(to:)`）。
/// `momentaryRatePressID` 记录当前临时倍速对应的按压，结束回调按它比对，旧按压迟到的结束不影响新的
/// 临时倍速。
@MainActor
final class NativePlayerHostView: AVPlayerView {
    /// 订阅章节提示，返回取消订阅的函数（`VideoChapterModel.observeAnnouncements`）。
    typealias ChapterAnnouncementObserving =
        @MainActor (
            @escaping @MainActor (VideoChapterAnnouncement) -> Void
        ) -> @MainActor () -> Void

    let danmakuOverlay: DanmakuOverlayView
    private let keyboardShortcuts = PlayerKeyboardShortcutController()
    private let overlayModel = PlayerOverlayModel()
    private let actionMenu = PlayerActionMenuController()
    private let playbackEndObserver = PlayerPlaybackEndObserver()
    /// 章节提示的订阅；挂上播放页时订阅，摘下与拆除时取消。
    private var cancelChapterAnnouncements: (@MainActor () -> Void)?
    private let overlayHostingView: PassthroughHostingView<PlayerOverlayView>
    private var installedDanmakuOverlay = false
    private var isPresentingFullScreen = false
    /// 画中画的状态与「还原」的交接；只有窗口留住的宿主有，由 `PlayerHostOwner` 交来。
    var pictureInPicture: PlayerPictureInPicture?
    /// 写入结果在全屏时改到播放器上显示；只有窗口留住的宿主有，由 `PlayerHostOwner` 交来。
    var writeResults: PlayerWriteResults? {
        didSet { overlayModel.writeResults = writeResults }
    }
    private var momentaryRateSessionID: UUID?
    private var momentaryRatePressID: UUID?
    private weak var observedPlayer: SeekTrackingPlayer?
    private var playerItemObservation: NSKeyValueObservation?
    private var playerTimeControlObservation: NSKeyValueObservation?
    private var playerWaitingReasonObservation: NSKeyValueObservation?
    private var playerSeekActivityObservers = NativeVideoNotificationObservers()
    private var currentItemObservations: [NSKeyValueObservation] = []
    private var playerItemTimeJumpObservers = NativeVideoNotificationObservers()
    private var blocksNativePlaybackInteraction = false
    private var lastInitialFocusIdentity: String?
    private var pendingInitialFocusIdentity: String?
    private var focusLossObservers = NativeVideoNotificationObservers()
    var requestMomentaryPlaybackRate: ((Float) -> UUID?)?
    var finishMomentaryPlaybackRate: ((UUID) -> Void)?
    var seekByTransportOffset: ((Double) -> Bool)?
    var adjustVolume: ((Float) -> Float)?
    var togglePlayback: (() -> Bool?)?
    var toggleDanmaku: (() -> Bool)?
    var toggleSubtitles: (() async -> NativeSubtitleToggleResult)?
    /// Q／W／E 与长按 Q 的意图；没有时这几个键只被吞掉、不提示。
    var engagementShortcuts: PlayerEngagementShortcuts?
    /// 发送弹幕的输入胶囊，画在浮层里（`PlayerOverlayModel.danmakuComposer`）。
    var danmakuComposer: DanmakuComposerModel? {
        get { overlayModel.danmakuComposer }
        set {
            guard overlayModel.danmakuComposer !== newValue else { return }
            overlayModel.danmakuComposer = newValue
        }
    }

    init(
        renderer: CoreAnimationDanmakuRenderer,
        controller: DanmakuPresentationController,
        beginMomentaryPlaybackRate: ((Float) -> UUID?)?,
        endMomentaryPlaybackRate: ((UUID) -> Void)?,
        seekByTransportOffset: ((Double) -> Bool)? = nil,
        adjustVolume: ((Float) -> Float)? = nil,
        togglePlayback: (() -> Bool?)? = nil,
        toggleDanmaku: (() -> Bool)? = nil,
        toggleSubtitles: (() async -> NativeSubtitleToggleResult)? = nil
    ) {
        danmakuOverlay = DanmakuOverlayView(
            renderer: renderer,
            controller: controller
        )
        requestMomentaryPlaybackRate = beginMomentaryPlaybackRate
        finishMomentaryPlaybackRate = endMomentaryPlaybackRate
        self.seekByTransportOffset = seekByTransportOffset
        self.adjustVolume = adjustVolume
        self.togglePlayback = togglePlayback
        self.toggleDanmaku = toggleDanmaku
        self.toggleSubtitles = toggleSubtitles
        overlayHostingView = PassthroughHostingView(
            rootView: PlayerOverlayView(model: overlayModel)
        )
        super.init(frame: .zero)
        delegate = self
        pictureInPictureDelegate = self
        // 控制条样式只设这一次。准备播放期间不切到 `.none`：每次从 `.none` 切回，AVKit 都重建整套控制条视图控制器，
        // 每打开或换一次视频主线程多挡约 30ms。准备期间改由 `setPlaybackPreparationBlocked` 屏蔽命中、第一响应者、
        // 快捷键与读屏，控制条照常显示但操作不到正在被替换的播放。
        controlsStyle = .default
        // 系统 Now Playing 只由进程级 `SystemNowPlayingController` 发布，AVKit
        // 自动更新会与它争写同一份信息。
        updatesNowPlayingInfoCenter = false
        // 保留 AVKit 的画面分析（实况文本），暂停帧上可以选取与查询文字。代价是它在 `pause()` 内的 rate KVO
        // 回调里于主线程读取 `currentTime`，等播放器为音频暂停握手持有的锁，暂停时主线程多挡约 20ms；弹幕时钟
        // 在自己的队列上跟随 timebase、不经过主线程，暂停时照样当场冻结，不受这段阻塞影响。
        allowsVideoFrameAnalysis = true
        overlayHostingView.sizingOptions = []
        // 浮层与 content overlay 等大；不按窗口安全区缩进，否则播放器滚到工具栏下或全屏时提示位置
        // 与“从头播放”的点击区域会偏移。
        overlayHostingView.safeAreaRegions = []
        overlayHostingView.interactiveFrames = { [overlayModel] in
            overlayModel.interactiveFrames
        }
        keyboardShortcuts.feedbackPresenter = overlayModel
        actionMenu.presentFeedback = { [overlayModel] feedback in
            overlayModel.showFeedback(.action(feedback))
        }
        actionMenu.openDanmakuComposer = { [overlayModel] in
            overlayModel.danmakuComposer?.present()
        }
        actionPopUpButtonMenu = actionMenu.menu
        keyboardShortcuts.onKeyboardMomentaryRateBegan = {
            [weak self] rate, pressID in
            self?.beginMomentaryPlaybackRate(rate, pressID: pressID)
        }
        keyboardShortcuts.onKeyboardMomentaryRateEnded = {
            [weak self] pressID in
            self?.endMomentaryPlaybackRate(ifPressID: pressID)
        }
        keyboardShortcuts.onRelativeSeek = { [weak self] offset in
            self?.seekByTransportOffset?(offset) ?? false
        }
        keyboardShortcuts.onVolumeStep = { [weak self] offset in
            self?.adjustVolume?(offset)
        }
        keyboardShortcuts.onTogglePlayback = { [weak self] in
            guard let togglePlayback = self?.togglePlayback else { return nil }
            return togglePlayback()
        }
        keyboardShortcuts.onToggleDanmaku = { [weak self] in
            self?.toggleDanmaku?()
        }
        keyboardShortcuts.onToggleSubtitles = { [weak self] in
            guard let toggleSubtitles = self?.toggleSubtitles else {
                return .unavailable
            }
            return await toggleSubtitles()
        }
        keyboardShortcuts.onToggleFullScreen = { [weak self] in
            self?.toggleFullScreen()
        }
        keyboardShortcuts.onToggleLike = { [weak self] in
            self?.engagementShortcuts?.toggleLike()
        }
        keyboardShortcuts.onTriple = { [weak self] in
            self?.engagementShortcuts?.triple()
        }
        // 投币与收藏的面板在主窗口里：AVKit 独立全屏时看不到，由意图改为提示先退出全屏。
        keyboardShortcuts.onOpenCoinPanel = { [weak self] in
            guard let self else { return nil }
            return self.engagementShortcuts?.openCoinPanel(self.isPresentingFullScreen)
        }
        keyboardShortcuts.onChooseFavoriteFolders = { [weak self] in
            guard let self else { return nil }
            return self.engagementShortcuts?.chooseFavoriteFolders(self.isPresentingFullScreen)
        }
        keyboardShortcuts.onOpenDanmakuComposer = { [overlayModel] in
            overlayModel.danmakuComposer?.present()
        }
        installDanmakuOverlayIfNeeded()
    }

    /// F 键切换 AVKit 全屏，与控制条全屏按钮走同一路径。
    ///
    /// AVKit 没有公开进入／退出全屏的方法；`enterFullScreen:`／`exitFullScreen:` 是本项目唯一使用的
    /// 私有 AVKit 接口。先确认响应再调用：系统移除后按 F 静默无效，全屏按钮不受影响。
    /// 是否处于全屏由公开的 `AVPlayerViewDelegate` 回调记录，不读私有状态。
    func toggleFullScreen() {
        guard showsFullScreenToggleButton, !blocksNativePlaybackInteraction else { return }
        let selector = NSSelectorFromString(
            isPresentingFullScreen ? "exitFullScreen:" : "enterFullScreen:"
        )
        guard responds(to: selector) else { return }
        perform(selector, with: nil)
    }

    override var acceptsFirstResponder: Bool {
        !blocksNativePlaybackInteraction
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !blocksNativePlaybackInteraction else { return nil }
        return super.hitTest(point)
    }

    /// 播放准备期间（换视频、切分 P、准备播放）屏蔽命中测试、第一响应者、快捷键与读屏，阻止操作正在被替换的播放；
    /// 原生控制条照常显示，不改控制条样式（理由见 `init`）。
    func setPlaybackPreparationBlocked(_ blocked: Bool) {
        let stateChanged = blocksNativePlaybackInteraction != blocked
        blocksNativePlaybackInteraction = blocked
        setAccessibilityHidden(blocked)
        keyboardShortcuts.setKeyboardInputEnabled(!blocked)
        updatePlaybackActivity()
        guard stateChanged else {
            if !blocked {
                applyPendingInitialKeyboardFocus()
            }
            return
        }
        if blocked {
            cancelMomentaryPlaybackRate()
        }
        if !blocked {
            applyPendingInitialKeyboardFocus()
        }
        guard blocked,
            let window,
            let responderView = window.firstResponder as? NSView,
            responderView === self || responderView.isDescendant(of: self)
        else { return }
        window.makeFirstResponder(nil)
    }

    func setResumeNotice(
        _ notice: PlaybackResumeNotice?,
        restartFromBeginning: @escaping () -> Void
    ) {
        overlayModel.setResumeNotice(notice, restartFromBeginning: restartFromBeginning)
    }

    /// 动作菜单的意图与打开网页的入口；宿主创建与每次更新时调用。
    func setActionMenu(_ actions: PlayerActionMenuActions, openURL: OpenURLAction) {
        actionMenu.update(actions: actions, openURL: openURL)
    }

    /// 宿主创建时开始按「播放结束后」处理播完，拆除时停止；提示显示在播放器浮层上。
    private func startPlaybackEndObservation(_ actions: PlayerPlaybackEndActions) {
        playbackEndObserver.start(actions) { [overlayModel] feedback in
            overlayModel.showFeedback(.action(feedback))
        }
    }

    private func stopPlaybackEndObservation() {
        playbackEndObserver.stop()
    }

    /// 章节模型的提示接到 AVKit 的章节浮层：在画面上短暂显示章节号与标题，全屏时也在画面上。
    ///
    /// 提示何时发出由 `VideoChapterModel` 决定，这里不再判断。
    private func startChapterAnnouncements(_ observe: ChapterAnnouncementObserving) {
        stopChapterAnnouncements()
        cancelChapterAnnouncements = observe { [weak self] announcement in
            self?.flashChapterNumber(announcement.number, chapterTitle: announcement.title)
        }
    }

    private func stopChapterAnnouncements() {
        cancelChapterAnnouncements?()
        cancelChapterAnnouncements = nil
    }

    func setPreviewEndedNotice(_ message: String?) {
        overlayModel.setPreviewEndedMessage(message)
    }

    /// 按播放器的最新状态重算两种转圈；每个观察回调回到主线程后都调用它，只读当下状态，不用回调带来的值，
    /// 跳回主线程期间状态又变了也以最新的为准。
    private func updatePlaybackActivity() {
        let item = player?.currentItem
        let seekActivity = observedPlayer?.seekActivity ?? .idle
        overlayModel.setPreparationActivity(
            isPreparing: blocksNativePlaybackInteraction,
            hasCurrentItem: item != nil
        )
        overlayModel.setWaitingForPicture(
            PlayerLoadingPolicy.isWaitingForPicture(
                isPreparing: blocksNativePlaybackInteraction,
                isItemReady: item?.status == .readyToPlay,
                hasPendingSeek: seekActivity.hasPendingSeek,
                timeControlStatus: player?.timeControlStatus ?? .paused,
                isPlaybackLikelyToKeepUp: item?.isPlaybackLikelyToKeepUp ?? false
            ),
            landedSeekCount: seekActivity.landedSeekCount
        )
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            stopObservingFocusLoss()
            cancelMomentaryPlaybackRate()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { pictureInPicture?.hostDidEnterWindow() }
        installDanmakuOverlayIfNeeded()
        startObservingFocusLoss()
        applyPendingInitialKeyboardFocus()
    }

    func requestInitialKeyboardFocus(for identity: String?) {
        guard let identity, identity != lastInitialFocusIdentity else { return }
        pendingInitialFocusIdentity = identity
        applyPendingInitialKeyboardFocus()
    }

    private func applyPendingInitialKeyboardFocus() {
        guard !blocksNativePlaybackInteraction,
            let identity = pendingInitialFocusIdentity,
            let window
        else { return }
        pendingInitialFocusIdentity = nil
        lastInitialFocusIdentity = identity
        // 评论图片预览在自己的子窗口面板里，这里只改播放窗口的第一响应者，不影响已打开的预览。
        window.makeFirstResponder(self)
    }

    /// 拆除宿主：常驻宿主由 `PlayerHostOwner.close()` 在关窗时调用一次，关窗后迟到挂载的不留住宿主由
    /// `AVPlayerContainerView` 在卸载时调用。
    ///
    /// 按顺序：写入结果交回窗口、清除提示、停止播完的处理与章节提示、撤销弹幕 surface、解开弹幕时钟与 item timebase 的绑定、停止失焦与 player
    /// 观察、停止键盘监听、结束临时倍速，最后断开 player，避免宿主继续呈现。
    func tearDown() {
        writeResults?.presentOnPlayer(false)
        setResumeNotice(nil, restartFromBeginning: {})
        setPreviewEndedNotice(nil)
        stopPlaybackEndObservation()
        stopChapterAnnouncements()
        danmakuOverlay.detachSurface()
        danmakuOverlay.bind(to: nil)
        stopObservingFocusLoss()
        stopObservingPlayerItemChanges()
        stopKeyboardMonitoring()
        cancelMomentaryPlaybackRate()
        player = nil
    }

    /// 播放页挂上宿主时调用，在宿主进入窗口之前：开始这一页的播完观察、章节提示与键盘监听，丢掉上一页留下的提示，按全屏状态取回
    /// 写入结果的位置，并清空初始焦点记录。
    ///
    /// 逐页的状态不随宿主常驻：清空焦点记录后，再次进入同一个视频时 `requestInitialKeyboardFocus` 照样把键盘焦点交给
    /// 播放器；上一页没消失的提示不会出现在新一页上。新容器可能先于旧容器卸载就把宿主取走，旧容器之后找不到宿主、
    /// 不会调用 `unmountFromPage()`，所以这里先停掉上一页的播完观察与章节提示再重新开始。键盘监听在弹幕层装上之前没有锚点
    /// 窗口，不处理按键。
    func mountInPage(
        playbackEnd: PlayerPlaybackEndActions,
        chapterAnnouncements: ChapterAnnouncementObserving
    ) {
        lastInitialFocusIdentity = nil
        pendingInitialFocusIdentity = nil
        overlayModel.clearFeedback()
        writeResults?.presentOnPlayer(isPresentingFullScreen)
        stopPlaybackEndObservation()
        startPlaybackEndObservation(playbackEnd)
        startChapterAnnouncements(chapterAnnouncements)
        keyboardShortcuts.startMonitoring()
    }

    /// 播放页卸载、宿主被摘下时调用：停止播完观察（连同在途的处理，迟到的连播与提示不再落到这一页）、章节提示与键盘监听，并把
    /// 写入结果交回窗口。
    ///
    /// player、弹幕绑定与 item 观察都保留，被换掉的页面带着画面离开；失焦观察与临时倍速在离开窗口时
    /// （`viewWillMove(toWindow:)`）收掉。
    func unmountFromPage() {
        // 全屏中离开播放页时 AVKit 是否先回调退出全屏不确定；不在播放页上就把结果交回窗口，挂上时按全屏状态再取回。
        writeResults?.presentOnPlayer(false)
        stopPlaybackEndObservation()
        stopChapterAnnouncements()
        stopKeyboardMonitoring()
    }

    func cancelMomentaryPlaybackRate() {
        keyboardShortcuts.cancelInputSession()
        if momentaryRateSessionID != nil {
            endMomentaryPlaybackRate()
        }
    }

    /// 挂上窗口播放器并开始观察；同一个播放器重复调用不重复注册。
    func attachPlayer(_ player: SeekTrackingPlayer) {
        self.player = player
        guard observedPlayer !== player else { return }
        stopObservingPlayerItemChanges()
        observedPlayer = player
        playerItemObservation = player.observe(\.currentItem, options: [.new]) {
            [weak self] _, _ in
            // `replaceCurrentItem` 只在主线程调用（`AVPlayerEngine` 是 @MainActor），这个 KVO 在调用内部同步
            // 触发：弹幕在这里同步清屏并换绑时钟，调用返回时新 item 上已没有旧弹幕，旧时钟也不会再多走一个主线程
            // 回合。不在主线程（违反前提）时 DEBUG 下断言失败，并退回下一个主线程回合换绑。
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.danmakuOverlay.bind(to: self?.player?.currentItem)
                }
            } else {
                assertionFailure("player currentItem changed off the main thread")
                Task { @MainActor in
                    self?.danmakuOverlay.bind(to: self?.player?.currentItem)
                }
            }
            Task { @MainActor in
                self?.cancelMomentaryPlaybackRate()
                self?.overlayModel.clearResumeNotice(markDismissed: true)
                self?.startObservingCurrentItem()
                self?.updatePlaybackActivity()
            }
        }
        // 状态直接读播放器，不用 change.newValue：timeControlStatus 是 Objective-C 枚举，KVO 字典里是
        // NSNumber，Swift 的 KeyPath 观察桥接不成这个枚举，newValue 恒为 nil，暂停就永远取消不了长按倍速。
        // volume、rate 这类数值与 Bool 属性的 newValue 不受影响。
        playerTimeControlObservation = player.observe(
            \.timeControlStatus,
            options: []
        ) {
            [weak self] player, _ in
            let paused = player.timeControlStatus == .paused
            Task { @MainActor in
                if paused {
                    self?.cancelMomentaryPlaybackRate()
                }
                self?.updatePlaybackActivity()
            }
        }
        playerWaitingReasonObservation = player.observe(
            \.reasonForWaitingToPlay,
            options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.updatePlaybackActivity()
            }
        }
        // seek 可能在任何线程发起与完成，通知由播放器异步投递到主队列，回调里读最新快照。
        playerSeekActivityObservers.observe(
            SeekTrackingPlayer.activityDidChangeNotification,
            object: player
        ) { [weak self] in
            self?.updatePlaybackActivity()
        }
        danmakuOverlay.bind(to: player.currentItem)
        startObservingCurrentItem()
        updatePlaybackActivity()
    }

    /// 观察当前 item 的就绪、“可能跟得上”与时间跳转；换 item 时由 `currentItem` 观察重新调用。
    ///
    /// 就绪与“可能跟得上”的变化不一定伴随 `timeControlStatus` 变化（例如等数据期间缓冲补足），转圈要靠它们
    /// 撤下或出现。
    private func startObservingCurrentItem() {
        for observation in currentItemObservations { observation.invalidate() }
        currentItemObservations = []
        playerItemTimeJumpObservers.removeAll()
        guard let item = player?.currentItem else { return }
        currentItemObservations = [
            item.observe(\.status, options: []) { [weak self] _, _ in
                Task { @MainActor in
                    self?.updatePlaybackActivity()
                }
            },
            item.observe(\.isPlaybackLikelyToKeepUp, options: []) { [weak self] _, _ in
                Task { @MainActor in
                    self?.updatePlaybackActivity()
                }
            }
        ]
        playerItemTimeJumpObservers.observe(
            AVPlayerItem.timeJumpedNotification,
            object: item
        ) { [weak self] in
            guard let self, let player = self.player, player.currentItem != nil
            else { return }
            self.overlayModel.observeTimeJump(toSeconds: player.currentTime().seconds)
        }
    }

    func stopObservingPlayerItemChanges() {
        playerItemObservation?.invalidate()
        playerItemObservation = nil
        playerTimeControlObservation?.invalidate()
        playerTimeControlObservation = nil
        playerWaitingReasonObservation?.invalidate()
        playerWaitingReasonObservation = nil
        playerSeekActivityObservers.removeAll()
        for observation in currentItemObservations { observation.invalidate() }
        currentItemObservations = []
        playerItemTimeJumpObservers.removeAll()
        observedPlayer = nil
    }

    private func installDanmakuOverlayIfNeeded() {
        guard !installedDanmakuOverlay,
            let contentOverlayView
        else {
            return
        }
        installedDanmakuOverlay = true
        danmakuOverlay.translatesAutoresizingMaskIntoConstraints = false
        contentOverlayView.addSubview(danmakuOverlay)
        // 快捷键以弹幕层所在窗口为准：AVKit detached 全屏只携带 content overlay，弹幕层随之移动。
        keyboardShortcuts.anchorView = danmakuOverlay
        overlayHostingView.translatesAutoresizingMaskIntoConstraints = false
        contentOverlayView.addSubview(
            overlayHostingView,
            positioned: .above,
            relativeTo: danmakuOverlay
        )
        // 弹幕层与浮层都与 content overlay 等大。
        for view in [danmakuOverlay, overlayHostingView] as [NSView] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: contentOverlayView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentOverlayView.trailingAnchor),
                view.topAnchor.constraint(equalTo: contentOverlayView.topAnchor),
                view.bottomAnchor.constraint(equalTo: contentOverlayView.bottomAnchor)
            ])
        }
    }

    private func beginMomentaryPlaybackRate(
        _ rate: PlayerMomentaryRate,
        pressID: UUID
    ) {
        if momentaryRatePressID != pressID {
            endMomentaryPlaybackRate()
        }
        guard let player,
            let item = player.currentItem,
            item.status == .readyToPlay,
            player.rate > 0,
            let sessionID = requestMomentaryPlaybackRate?(rate.rawValue)
        else {
            clearMomentaryPlaybackRate()
            return
        }
        momentaryRateSessionID = sessionID
        momentaryRatePressID = pressID
        overlayModel.showMomentaryRate(rate)
    }

    private func endMomentaryPlaybackRate(ifPressID pressID: UUID) {
        guard momentaryRatePressID == pressID else { return }
        endMomentaryPlaybackRate()
    }

    private func endMomentaryPlaybackRate() {
        if let momentaryRateSessionID {
            finishMomentaryPlaybackRate?(momentaryRateSessionID)
        }
        clearMomentaryPlaybackRate()
    }

    private func clearMomentaryPlaybackRate() {
        momentaryRateSessionID = nil
        momentaryRatePressID = nil
        overlayModel.endMomentaryRate()
    }

    /// App 失活或任一窗口失去 key 时结束长按临时倍速。
    ///
    /// 不只观察宿主所在窗口：detached 全屏时按键发生在 AVKit 的全屏窗口里。长按要求持续按住，
    /// 窗口焦点一变这次长按就应结束，因此不区分是哪个窗口。
    private func startObservingFocusLoss() {
        focusLossObservers.removeAll()
        guard requestMomentaryPlaybackRate != nil,
            finishMomentaryPlaybackRate != nil,
            window != nil
        else {
            return
        }
        focusLossObservers.observe(
            NSApplication.didResignActiveNotification,
            object: nil
        ) { [weak self] in
            self?.cancelMomentaryPlaybackRate()
        }
        focusLossObservers.observe(
            NSWindow.didResignKeyNotification,
            object: nil
        ) { [weak self] in
            self?.cancelMomentaryPlaybackRate()
        }
    }

    func stopObservingFocusLoss() {
        focusLossObservers.removeAll()
    }

    private func stopKeyboardMonitoring() {
        keyboardShortcuts.cancelInputSession()
        keyboardShortcuts.stopMonitoring()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

extension NativePlayerHostView: AVPlayerViewDelegate {
    func playerViewWillEnterFullScreen(_ playerView: AVPlayerView) {
        isPresentingFullScreen = true
        writeResults?.presentOnPlayer(true)
    }

    func playerViewWillExitFullScreen(_ playerView: AVPlayerView) {
        isPresentingFullScreen = false
        writeResults?.presentOnPlayer(false)
    }
}
