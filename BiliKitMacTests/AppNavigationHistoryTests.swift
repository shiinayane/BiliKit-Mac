import BiliApplication
import BiliBrowseFeature
import BiliModels
import BiliVideoDetailFeature
import Testing

@testable import BiliKit

/// 右侧历史栈里活视频被浏览类页面（空间页、搜索页）盖住、回来与被取代后重建的规则：被盖住时不出声（画中画除外），回来只恢复由盖住暂停、
/// 被盖住期间用户也没动过的，被取代的按离开时的分 P 与秒数重建，并按离开先后记进「刚才看过」。
@MainActor
struct AppNavigationHistoryTests {
    private let owner = VideoOwner(id: 7, name: "UP 主")
    private let anotherOwner = VideoOwner(id: 8, name: "另一位 UP 主")

    /// 盖住活视频的浏览类页面；两种页面共用协调器里同一支盖住与返回。
    enum CoveringPage: CaseIterable {
        case space
        case search

        @MainActor
        func open(on coordinator: AppNavigationCoordinator) {
            switch self {
            case .space: coordinator.openUploaderSpacePage(owner: VideoOwner(id: 7, name: "UP 主"))
            case .search: coordinator.openSearchPage(keyword: "关键词")
            }
        }
    }

    @Test(arguments: [true, false], CoveringPage.allCases)
    func coveringPausesAndReturningResumesOnlyWhatCoveringPaused(
        wasPlaying: Bool,
        covering: CoveringPage
    ) {
        let playback = PlaybackRecorder()
        playback.isPlaying = wasPlaying
        let coordinator = playback.makeCoordinator()

        coordinator.openPlayback("BV1Covered")
        covering.open(on: coordinator)
        #expect(coordinator.currentPlaybackBVID == nil)
        #expect(coordinator.livePlaybackBVID == "BV1Covered")
        coordinator.goBack()

        #expect(coordinator.currentPlaybackBVID == "BV1Covered")
        #expect(
            playback.events == ["start:BV1Covered", "pause"] + (wasPlaying ? ["resume"] : [])
        )
    }

    /// 被盖住期间用户经媒体键播放过、又暂停了：位置已经不是盖住时的，回来按用户此刻的暂停保持不动。
    @Test
    func playbackTheUserMovedWhileCoveredIsNotResumed() {
        let playback = PlaybackRecorder()
        playback.position = 30
        let coordinator = playback.makeCoordinator()

        coordinator.openPlayback("BV1Covered")
        coordinator.openUploaderSpacePage(owner: owner)
        playback.position = 42
        coordinator.goBack()

        #expect(playback.events == ["start:BV1Covered", "pause"])
    }

    /// 还在加载时暂停拦不住随后的自动起播，所以被盖住就停止；回来时按原来的意图重新加载。
    @Test
    func aVideoStillLoadingIsStoppedWhenCoveredAndReloadedOnReturn() {
        let playback = PlaybackRecorder()
        playback.isPresenting = false
        let coordinator = playback.makeCoordinator()

        coordinator.openPlayback("BV1Loading")
        coordinator.openUploaderSpacePage(owner: owner)
        #expect(coordinator.livePlaybackBVID == nil)
        coordinator.goBack()

        #expect(playback.events == ["start:BV1Loading", "stop", "start:BV1Loading"])
        #expect(coordinator.livePlaybackBVID == "BV1Loading")
    }

    @Test
    func aReplacedVideoIsRebuiltFromWhereItWasLeft() {
        let playback = PlaybackRecorder()
        playback.resumePoint = PlaybackSelectionIntent(
            bvid: "BV1First",
            preferredCID: 3,
            preferredStartSeconds: 42
        )
        let coordinator = playback.makeCoordinator()

        coordinator.openPlayback("BV1First")
        coordinator.openUploaderSpacePage(owner: owner)
        coordinator.openPlayback("BV1Second")
        coordinator.goBack()
        coordinator.goBack()

        #expect(
            playback.events == [
                "start:BV1First", "pause", "start:BV1Second", "pause", "stop", "start:BV1First"
            ]
        )
        #expect(playback.lastStart == playback.resumePoint)
    }

    /// 「刚才看过」最近离开的在前、按 BVID 去重、不含正在播放的；从里面点回去的视频移出列表。
    @Test
    func replacedVideosAreListedNewestFirstExceptTheOneNowPlaying() {
        let playback = PlaybackRecorder()
        let coordinator = playback.makeCoordinator()

        coordinator.openPlayback("BV1A")
        playback.resumePoint = Self.point("BV1A", seconds: 30)
        coordinator.openPlayback("BV1B")
        playback.resumePoint = Self.point("BV1B", seconds: 40)
        coordinator.openPlayback("BV1C")

        #expect(coordinator.recentlyWatched.map(\.id) == ["BV1B", "BV1A"])
        #expect(
            coordinator.recentlyWatched.map(\.resumePoint) == [
                Self.point("BV1B", seconds: 40), Self.point("BV1A", seconds: 30)
            ]
        )

        playback.resumePoint = Self.point("BV1C", seconds: 50)
        coordinator.openPlayback(coordinator.recentlyWatched[1].resumePoint)
        #expect(coordinator.recentlyWatched.map(\.id) == ["BV1C", "BV1B"])
        #expect(playback.lastStart == Self.point("BV1A", seconds: 30))
    }

    /// 回到来源根页就结束这一段：不论经 ⌂、一路「返回」还是换来源，之后打开的视频看不到之前的「刚才看过」。
    @Test(arguments: RootReturn.allCases)
    func returningToTheSourceRootClearsTheList(_ route: RootReturn) {
        let playback = PlaybackRecorder()
        let coordinator = playback.makeCoordinator()

        coordinator.openPlayback("BV1A")
        coordinator.openPlayback("BV1B")
        #expect(coordinator.recentlyWatched.map(\.id) == ["BV1A"])
        switch route {
        case .home:
            coordinator.goHome()
        case .back:
            coordinator.goBack()
            coordinator.goBack()
        case .sidebar:
            coordinator.closeForSidebarSelection()
        }
        #expect(!coordinator.canGoBack)
        coordinator.openPlayback("BV1C")

        #expect(coordinator.recentlyWatched.isEmpty)
    }

    enum RootReturn: CaseIterable {
        case home
        case back
        case sidebar
    }

    /// 经「返回」离开的视频历史里已没有它那一项，也记进「刚才看过」，从离开的位置续播。
    @Test
    func aVideoLeftThroughBackIsListedToo() {
        let playback = PlaybackRecorder()
        let coordinator = playback.makeCoordinator()

        coordinator.openPlayback("BV1A")
        coordinator.openUploaderSpacePage(owner: owner)
        coordinator.openPlayback("BV1B")
        playback.resumePoint = Self.point("BV1B", seconds: 20)
        coordinator.goBack()

        #expect(coordinator.recentlyWatched.first?.resumePoint == Self.point("BV1B", seconds: 20))
    }

    /// 还没播起来就切走的按离开的视频从头记；离开时已到分 P 结尾的标为看完，点开也从头播。
    @Test
    func videosLeftBeforePlayingOrAtTheEndResumeFromTheStart() {
        let playback = PlaybackRecorder()
        let coordinator = playback.makeCoordinator()

        coordinator.openPlayback("BV1A")
        coordinator.openPlayback("BV1B")
        playback.resumePoint = Self.point("BV1B", seconds: 115)
        coordinator.openPlayback("BV1C")

        let leftAtStart = coordinator.recentlyWatched.first { $0.id == "BV1A" }
        let leftAtEnd = coordinator.recentlyWatched.first { $0.id == "BV1B" }
        #expect(leftAtStart?.resumePoint.preferredStartSeconds == nil)
        #expect(leftAtStart?.isFinished == false)
        #expect(leftAtEnd?.resumePoint.preferredStartSeconds == nil)
        #expect(leftAtEnd?.resumePoint.preferredCID == VideoFixture().page.cid)
        #expect(leftAtEnd?.isFinished == true)
    }

    /// `VideoFixture` 的分 P（120 秒）上的一个离开位置。
    private static func point(_ bvid: String, seconds: Int) -> PlaybackSelectionIntent {
        PlaybackSelectionIntent(
            bvid: bvid,
            preferredCID: VideoFixture().page.cid,
            preferredStartSeconds: seconds
        )
    }

    /// 空间页里又点了被盖住的那个视频：不重新起播，继续同一个；从它返回空间页时下面还是同一个视频，又按被盖住处理。
    @Test
    func reopeningTheCoveredVideoKeepsPlayingIt() {
        let playback = PlaybackRecorder()
        let coordinator = playback.makeCoordinator()

        coordinator.openPlayback("BV1Same")
        coordinator.openUploaderSpacePage(owner: owner)
        coordinator.openPlayback("BV1Same")
        #expect(coordinator.currentPlaybackBVID == "BV1Same")
        coordinator.goBack()
        coordinator.goBack()

        #expect(playback.events == ["start:BV1Same", "pause", "resume", "pause", "resume"])
        #expect(coordinator.history.count == 1)
    }

    /// 播完后的下一集在空间页盖住之后才解析回来：不换片、不起播，栈顶仍是空间页。
    @Test
    func aLateContinuationWhileCoveredIsIgnored() {
        let playback = PlaybackRecorder()
        let coordinator = playback.makeCoordinator()

        coordinator.openPlayback("BV1Ending")
        coordinator.openUploaderSpacePage(owner: owner)
        coordinator.continuePlayback("BV1Next", preferredCID: 2)

        #expect(playback.events == ["start:BV1Ending", "pause"])
        #expect(coordinator.currentPlaybackBVID == nil)
    }

    /// 整页空间模型被后来的空间项占用过，回到更早的空间项时按它当时的 UP 主与排序重建。
    @Test
    func returningToAnEarlierSpaceRestoresItsOrder() {
        let playback = PlaybackRecorder()
        let page = makeUploaderSpace()
        let coordinator = playback.makeCoordinator(uploaderSpacePage: page)

        coordinator.openPlayback("BV1First")
        coordinator.openUploaderSpacePage(owner: owner)
        page.setOrder(.mostPlayed)
        coordinator.openPlayback("BV1Second")
        coordinator.openUploaderSpacePage(owner: anotherOwner)
        #expect(page.owner == anotherOwner)
        #expect(page.order == .newest)
        coordinator.goBack()
        coordinator.goBack()

        #expect(page.owner == owner)
        #expect(page.order == .mostPlayed)
    }

    /// 压栈搜索模型被后来的搜索项占用过，回到更早的搜索项时按它当时的查询词与排序重建；重建不是用户的提交，不写搜索历史。
    @Test
    func returningToAnEarlierSearchRestoresItsConditionsWithoutRecordingHistory() {
        let playback = PlaybackRecorder()
        let recorded = KeywordRecorder()
        let page = makeSearchPage(recordHistory: { recorded.keywords.append($0) })
        let coordinator = playback.makeCoordinator(searchPage: page)

        coordinator.openPlayback("BV1First")
        coordinator.openSearchPage(keyword: "  关键词  ")
        page.session.filterSelection.order = .mostPlayed
        page.session.selectOrder(.mostPlayed)
        coordinator.openPlayback("BV1Second")
        coordinator.openSearchPage(keyword: "另一个")
        #expect(page.session.submittedCriteria == VideoSearchCriteria(query: "另一个"))
        coordinator.goBack()
        coordinator.goBack()

        #expect(
            page.session.submittedCriteria == VideoSearchCriteria(query: "关键词", order: .mostPlayed)
        )
        #expect(page.session.filterSelection.order == .mostPlayed)
        #expect(recorded.keywords.isEmpty)
    }

    /// 整页空间模型在空间页被盖住时被关掉（认证会话切换），回到这一项时按它记下的条件重新打开，不停在骨架屏。
    @Test
    func returningToASpaceWhoseModelWasClosedReopensIt() {
        let playback = PlaybackRecorder()
        let page = makeUploaderSpace()
        let coordinator = playback.makeCoordinator(uploaderSpacePage: page)

        coordinator.openPlayback("BV1First")
        coordinator.openUploaderSpacePage(owner: owner)
        page.setOrder(.mostPlayed)
        coordinator.openPlayback("BV1Second")
        page.close()
        coordinator.goBack()

        #expect(page.owner == owner)
        #expect(page.order == .mostPlayed)
    }

    /// 画中画中被盖住继续播放，回来不再继续；画中画在被盖住时被关掉，按被盖住暂停，回来再继续。
    @Test
    func pictureInPictureKeepsPlayingWhileCoveredUntilItIsClosed() {
        let playback = PlaybackRecorder()
        playback.isPictureInPictureActive = true
        let coordinator = playback.makeCoordinator()

        coordinator.openPlayback("BV1Floating")
        coordinator.openUploaderSpacePage(owner: owner)
        #expect(playback.events == ["start:BV1Floating"])
        playback.isPictureInPictureActive = false
        coordinator.pictureInPictureDidStopWithoutRestore()
        coordinator.goBack()

        #expect(playback.events == ["start:BV1Floating", "pause", "resume"])
    }

    /// 「还原」弹掉盖在活视频播放页上面的所有层，画中画里一直在播，不再继续或暂停；没有活视频时不能还原。
    @Test
    func restoringPictureInPictureReturnsToTheLivePlaybackPage() {
        let playback = PlaybackRecorder()
        playback.isPictureInPictureActive = true
        let coordinator = playback.makeCoordinator()

        coordinator.openPlayback("BV1Floating")
        coordinator.openUploaderSpacePage(owner: owner)
        #expect(coordinator.restoreLivePlaybackPage())

        #expect(coordinator.history.count == 1)
        #expect(coordinator.currentPlaybackBVID == "BV1Floating")
        #expect(playback.events == ["start:BV1Floating"])
        coordinator.goHome()
        #expect(!coordinator.restoreLivePlaybackPage())
    }

    /// ⌂ 从活视频的播放页出发时先暂停、转场结束后停止；从空间页出发时没有画面可留，立即停止。
    ///
    /// 已在根页时再回根页（点当前来源的侧栏行）不转场、不停止。
    @Test(arguments: [true, false])
    func goingHomeDefersTheStopOnlyFromTheLivePage(fromLivePage: Bool) {
        let playback = PlaybackRecorder()
        var pendingCompletion: (() -> Void)?
        var transitionCount = 0
        let coordinator = playback.makeCoordinator { direction, change, completion in
            transitionCount += 1
            change()
            if direction == .pop {
                pendingCompletion = completion
            } else {
                completion()
            }
        }

        coordinator.openPlayback("BV1Home")
        if !fromLivePage { coordinator.openUploaderSpacePage(owner: owner) }
        coordinator.goHome()
        let beforeTransitionEnds = playback.events
        pendingCompletion?()

        #expect(coordinator.history.isEmpty)
        #expect(beforeTransitionEnds == ["start:BV1Home", "pause"] + (fromLivePage ? [] : ["stop"]))
        #expect(playback.events == ["start:BV1Home", "pause", "stop"])
        let transitionsAtRoot = transitionCount
        coordinator.goHome()
        #expect(transitionCount == transitionsAtRoot)
        #expect(playback.events == ["start:BV1Home", "pause", "stop"])
    }
}

/// 本 Suite 的播放替身：记录开始、暂停、继续与停止，可设“有没有画面”“在不在播放”与续播点。
///
/// 「刚才看过」的标题等取自同 BVID 的 `VideoFixture`；经共用的 `makeNavigationCoordinator` 构造协调器。
@MainActor
private final class PlaybackRecorder {
    var events: [String] = []
    var isPresenting = true
    var isPlaying = true
    var position: Double?
    var resumePoint: PlaybackSelectionIntent?
    var isPictureInPictureActive = false
    private(set) var lastStart: PlaybackSelectionIntent?

    func makeCoordinator(
        uploaderSpacePage: UploaderSpaceViewModel = makeUploaderSpace(),
        searchPage: SearchPageModel = makeSearchPage(),
        transitionPage:
            @escaping (
                AppPageTransition, _ change: () -> Void, _ completion: @escaping () -> Void
            ) -> Void = { _, change, completion in
                change()
                completion()
            }
    ) -> AppNavigationCoordinator {
        makeNavigationCoordinator(
            startPlayback: { [unowned self] intent in
                events.append("start:\(intent.bvid)")
                lastStart = intent
            },
            stopPlayback: { [unowned self] in events.append("stop") },
            pausePlayback: { [unowned self] in
                guard isPresenting else { return false }
                events.append("pause")
                return true
            },
            isPlaying: { [unowned self] in isPresenting && isPlaying },
            resumePlayback: { [unowned self] in events.append("resume") },
            presentedPosition: { [unowned self] in isPresenting ? position : nil },
            resumePoint: { [unowned self] in resumePoint },
            recentlyWatchedEntry: { point in
                RecentlyWatchedVideo(
                    detail: VideoFixture(bvid: point.bvid).detail,
                    resumePoint: point
                )
            },
            isPictureInPictureActive: { [unowned self] in isPictureInPictureActive },
            transitionPage: transitionPage,
            uploaderSpacePage: uploaderSpacePage,
            searchPage: searchPage
        )
    }
}

/// 记下写入搜索历史的查询词。
@MainActor
private final class KeywordRecorder {
    var keywords: [String] = []
}
