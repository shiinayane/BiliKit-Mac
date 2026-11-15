import BiliApplication
import BiliAuthFeature
import BiliModels
import BiliVideoDetailFeature
import Foundation
import Observation
import Synchronization
import Testing

@testable import BiliKit

/// 播放页在来源之上只有一层，打开、替换与重试不重复开始播放，返回、换来源、关窗与登录变化各只停止一次；只有进出播放页
/// 转场，返回时先暂停、转场结束才停止。
///
/// 返回与登录变化保留来源，关窗复位到首页；侧栏上下文层只在从它自己打开视频时保留，关闭播放时随之关闭一次。
@Suite(.timeLimit(.minutes(1)))
struct AppNavigationCoordinatorTests {
    @Test(arguments: AppTab.allCases)
    @MainActor
    func backReturnsEachSourceAndStopsOnce(source: AppTab) {
        var events: [String] = []
        let coordinator = makeNavigationCoordinator(
            stopPlayback: { events.append("stop") },
            pausePlayback: {
                events.append("pause")
                return true
            },
            transitionPage: { direction, change, completion in
                events.append("transition:\(direction)")
                change()
                completion()
            }
        )
        coordinator.selectedTab = source

        coordinator.openPlayback("BV1Source")
        // 工具栏「返回」在按钮消失前可能被连点两次。
        coordinator.goBack()
        coordinator.goBack()

        #expect(coordinator.selectedTab == source)
        #expect(coordinator.currentPlaybackBVID == nil)
        #expect(events == ["transition:push", "pause", "transition:pop", "stop"])
    }

    /// 返回时先暂停、转场结束才停止；转场还没结束就又进了播放页时，先完成上一次停止再开始，晚到的转场结束不再停止。
    @Test
    @MainActor
    func backDefersTheStopUntilItsTransitionEnds() {
        var events: [String] = []
        var pendingCompletion: (() -> Void)?
        let coordinator = makeNavigationCoordinator(
            startPlayback: { events.append("start:\($0.bvid)") },
            stopPlayback: { events.append("stop") },
            pausePlayback: {
                events.append("pause")
                return true
            },
            transitionPage: { direction, change, completion in
                events.append("transition:\(direction)")
                change()
                if direction == .pop {
                    pendingCompletion = completion
                } else {
                    completion()
                }
            }
        )

        coordinator.openPlayback("BV1First")
        coordinator.goBack()
        #expect(coordinator.currentPlaybackBVID == nil)
        #expect(events == ["transition:push", "start:BV1First", "pause", "transition:pop"])

        coordinator.openPlayback("BV1Second")
        pendingCompletion?()

        #expect(coordinator.currentPlaybackBVID == "BV1Second")
        #expect(
            events == [
                "transition:push", "start:BV1First", "pause", "transition:pop",
                "stop", "transition:push", "start:BV1Second"
            ]
        )
    }

    /// 还没有画面可留（仍在加载）时返回照样转场，但立即停止，不等转场结束：否则加载在转场里完成会在根页上起播。
    @Test
    @MainActor
    func backWithoutAPictureStopsAtOnce() {
        var events: [String] = []
        var pendingCompletion: (() -> Void)?
        let coordinator = makeNavigationCoordinator(
            stopPlayback: { events.append("stop") },
            pausePlayback: { false },
            transitionPage: { direction, change, completion in
                events.append("transition:\(direction)")
                change()
                if direction == .pop {
                    pendingCompletion = completion
                } else {
                    completion()
                }
            }
        )

        coordinator.openPlayback("BV1Loading")
        coordinator.goBack()
        #expect(coordinator.currentPlaybackBVID == nil)
        #expect(events == ["transition:push", "transition:pop", "stop"])

        pendingCompletion?()
        #expect(events == ["transition:push", "transition:pop", "stop"])
    }

    /// 返回的转场进行中，播完的自动连播（下一集在转场里解析回来）不把用户拉回播放页，转场结束照常停止。
    @Test
    @MainActor
    func continuationDuringTheBackTransitionIsIgnored() {
        var events: [String] = []
        var pendingCompletion: (() -> Void)?
        let coordinator = makeNavigationCoordinator(
            startPlayback: { events.append("start:\($0.bvid)") },
            stopPlayback: { events.append("stop") },
            pausePlayback: {
                events.append("pause")
                return true
            },
            transitionPage: { direction, change, completion in
                events.append("transition:\(direction)")
                change()
                if direction == .pop {
                    pendingCompletion = completion
                } else {
                    completion()
                }
            }
        )

        coordinator.openPlayback("BV1First")
        coordinator.goBack()
        coordinator.continuePlayback("BV1Next", preferredCID: 2)
        pendingCompletion?()

        #expect(coordinator.currentPlaybackBVID == nil)
        #expect(events == ["transition:push", "start:BV1First", "pause", "transition:pop", "stop"])
    }

    /// 返回的转场进行中换来源、登出或关窗：立即停止且不再转场，晚到的转场结束不重复停止。
    @Test(arguments: ["tab", "authentication", "window"])
    @MainActor
    func closingDuringTheBackTransitionStopsAtOnce(trigger: String) {
        var events: [String] = []
        var pendingCompletion: (() -> Void)?
        let coordinator = makeNavigationCoordinator(
            stopPlayback: { events.append("stop") },
            pausePlayback: {
                events.append("pause")
                return true
            },
            transitionPage: { direction, change, completion in
                events.append("transition:\(direction)")
                change()
                pendingCompletion = completion
            }
        )
        coordinator.openPlayback("BV1Leaving")
        coordinator.goBack()

        switch trigger {
        case "tab":
            coordinator.selectedTab = .popular
        case "authentication":
            coordinator.closePlaybackForAuthenticationChange()
        default:
            coordinator.resetForWindowClosure()
        }
        pendingCompletion?()

        #expect(events == ["transition:push", "pause", "transition:pop", "stop"])
    }

    @Test
    @MainActor
    func replacementKeepsSourceWhileOrderingSideEffects() {
        var events: [String] = []
        let coordinator = makeNavigationCoordinator(
            startPlayback: { events.append("start:\($0.bvid)") },
            stopPlayback: { events.append("stop") },
            transitionPage: { direction, change, completion in
                events.append("transition:\(direction)")
                change()
                completion()
            },
            uploaderSpace: makeUploaderSpace()
        )
        coordinator.selectedTab = .search

        coordinator.openPlayback("BV1RouteA")
        coordinator.openPlayback("BV1RouteB")
        coordinator.openPlayback("BV1RouteC")

        #expect(coordinator.currentPlaybackBVID == "BV1RouteC")
        #expect(coordinator.selectedTab == .search)
        // 只有从来源页进入播放页时转场一次；在播放页里换视频是同类替换，不转场。
        #expect(
            events == [
                "transition:push",
                "start:BV1RouteA",
                "start:BV1RouteB",
                "start:BV1RouteC"
            ]
        )
    }

    @Test
    @MainActor
    func reopeningCurrentPlaybackDoesNotDuplicateLoad() {
        var startCount = 0
        let coordinator = makeNavigationCoordinator(
            startPlayback: { _ in startCount += 1 },
            stopPlayback: {},
            uploaderSpace: makeUploaderSpace()
        )

        coordinator.openPlayback("BV1SameA")
        coordinator.openPlayback("BV1SameA")

        #expect(startCount == 1)
    }

    @Test
    @MainActor
    func sameBVIDDifferentCIDIsANewAtomicSelectionIntent() {
        var intents: [PlaybackSelectionIntent] = []
        let coordinator = makeNavigationCoordinator(
            startPlayback: { intents.append($0) },
            stopPlayback: {},
            uploaderSpace: makeUploaderSpace()
        )

        coordinator.openPlayback(
            PlaybackSelectionIntent(bvid: "BV1SameA", preferredCID: 101)
        )
        coordinator.openPlayback(
            PlaybackSelectionIntent(bvid: "BV1SameA", preferredCID: 102)
        )

        #expect(intents.map(\.preferredCID) == [101, 102])
        #expect(coordinator.currentPlaybackIntent?.preferredCID == 102)
    }

    @Test
    @MainActor
    func retryKeepsMediaIdentity() {
        var intents: [PlaybackSelectionIntent] = []
        let coordinator = makeNavigationCoordinator(
            startPlayback: { intents.append($0) },
            stopPlayback: {},
            uploaderSpace: makeUploaderSpace()
        )

        coordinator.openPlayback(
            PlaybackSelectionIntent(bvid: "BV1RetryA", preferredCID: 202)
        )
        coordinator.retryPlayback()

        #expect(coordinator.currentPlaybackBVID == "BV1RetryA")
        #expect(intents.map(\.preferredCID) == [202, 202])
    }

    @Test
    @MainActor
    func selectingAnotherSourceClosesPlaybackExactlyOnce() {
        var stopCount = 0
        let coordinator = makeNavigationCoordinator(
            startPlayback: { _ in },
            stopPlayback: { stopCount += 1 },
            uploaderSpace: makeUploaderSpace()
        )

        coordinator.openPlayback("BV1SidebarA")
        coordinator.selectedTab = .search
        coordinator.selectedTab = .search

        #expect(coordinator.selectedTab == .search)
        #expect(coordinator.currentPlaybackBVID == nil)
        #expect(stopCount == 1)
    }

    @Test
    @MainActor
    func windowClosureIsIdempotentAndResetsWindowState() {
        var stopCount = 0
        let coordinator = makeNavigationCoordinator(
            startPlayback: { _ in },
            stopPlayback: { stopCount += 1 },
            uploaderSpace: makeUploaderSpace()
        )
        coordinator.selectedTab = .history
        coordinator.openPlayback("BV1CloseA")

        coordinator.resetForWindowClosure()
        coordinator.resetForWindowClosure()

        #expect(stopCount == 1)
        #expect(coordinator.selectedTab == .home)
        #expect(coordinator.currentPlaybackBVID == nil)
    }

    @Test
    @MainActor
    func authenticationChangeClosesPlaybackWithoutLosingSourceContext() {
        var stopCount = 0
        let coordinator = makeNavigationCoordinator(
            startPlayback: { _ in },
            stopPlayback: { stopCount += 1 },
            uploaderSpace: makeUploaderSpace()
        )
        coordinator.selectedTab = .search
        coordinator.openPlayback("BV1Logout")

        coordinator.closePlaybackForAuthenticationChange()
        coordinator.closePlaybackForAuthenticationChange()

        #expect(stopCount == 1)
        #expect(coordinator.selectedTab == .search)
        #expect(coordinator.currentPlaybackBVID == nil)
    }

    @Test
    @MainActor
    func choosingFromTheSidebarContextKeepsIt() {
        let space = makeUploaderSpace()
        var contextOpenAtStart: [Bool] = []
        let coordinator = makeNavigationCoordinator(
            startPlayback: { _ in contextOpenAtStart.append(space.owner != nil) },
            stopPlayback: {},
            uploaderSpace: space
        )
        coordinator.openPlayback("BV1Source")
        coordinator.openUploaderSpace(owner: VideoOwner(id: 42, name: "UP"))

        coordinator.openPlaybackFromSidebarContext("BV1FromSpace")

        #expect(contextOpenAtStart == [false, true])
        #expect(coordinator.isSidebarContextOpen)
        #expect(coordinator.currentPlaybackBVID == "BV1FromSpace")
    }

    /// 其他入口换视频先关闭上下文层再开始播放；重新打开正在播放的视频也关闭它。
    @Test
    @MainActor
    func otherEntriesCloseTheSidebarContextEvenForTheCurrentVideo() {
        let space = makeUploaderSpace()
        var events: [String] = []
        let coordinator = makeNavigationCoordinator(
            startPlayback: { events.append("start:\($0.bvid) context:\(space.owner != nil)") },
            stopPlayback: { events.append("stop") },
            uploaderSpace: space
        )
        coordinator.openPlayback("BV1Source")
        events.removeAll()

        coordinator.openUploaderSpace(owner: VideoOwner(id: 42, name: "UP"))
        coordinator.openPlayback("BV1Related")
        #expect(!coordinator.isSidebarContextOpen)

        coordinator.openUploaderSpace(owner: VideoOwner(id: 42, name: "UP"))
        coordinator.openPlayback("BV1Related")

        #expect(!coordinator.isSidebarContextOpen)
        #expect(events == ["start:BV1Related context:false"])
    }

    /// 关闭播放时上下文层只关一次：之后重复的关闭播放不再动它。
    @Test(arguments: ["tab", "authentication", "back"])
    @MainActor
    func closingPlaybackClosesTheSidebarContextOnce(trigger: String) async {
        let space = makeUploaderSpace()
        var events: [String] = []
        let coordinator = makeNavigationCoordinator(
            startPlayback: { _ in },
            stopPlayback: { events.append("stop context:\(space.owner != nil)") },
            uploaderSpace: space
        )
        coordinator.openPlayback("BV1Source")
        coordinator.openUploaderSpace(owner: VideoOwner(id: 42, name: "UP"))
        coordinator.openPlaybackFromSidebarContext("BV1FromSpace")
        // 空间投稿读取恒失败；等它落定，之后空间模型的变化只来自关闭。
        await waitForObservedState {
            if case .failed = space.state { return true }
            return false
        }
        let closeCount = Mutex(0)
        func countNextClose() {
            withObservationTracking {
                _ = space.owner
            } onChange: {
                closeCount.withLock { $0 += 1 }
            }
        }

        countNextClose()
        switch trigger {
        case "tab":
            coordinator.selectedTab = .popular
        case "authentication":
            coordinator.closePlaybackForAuthenticationChange()
        default:
            coordinator.goBack()
        }
        countNextClose()
        coordinator.closePlaybackForAuthenticationChange()

        #expect(!coordinator.isSidebarContextOpen)
        #expect(closeCount.withLock { $0 } == 1)
        #expect(events == ["stop context:false"])
    }

    /// 空间链接只有 MID：在侧栏空间层打开，并补取名片。
    @Test
    @MainActor
    func memberIDLinksOpenTheSpace() async throws {
        let profiles = UploaderProfileRepositoryStub(holdsRequests: true)
        let space = makeUploaderSpace(profiles: profiles)
        let coordinator = makeNavigationCoordinator(
            startPlayback: { _ in },
            stopPlayback: {},
            uploaderSpace: space
        )

        coordinator.openUploaderSpace(ownerID: 42)

        #expect(space.owner?.id == 42)
        #expect(coordinator.isSidebarContextOpen)
        // 只有 MID 的入口会补取名片：放行它，不留下挂起的请求。
        try await profiles.waitForRequest()
        await profiles.releaseLateResult()
    }

    @Test
    @MainActor
    func emptyBVIDDoesNotCreatePlaybackState() {
        var events: [String] = []
        let coordinator = makeNavigationCoordinator(
            startPlayback: { events.append("start:\($0.bvid)") },
            stopPlayback: { events.append("stop") },
            uploaderSpace: makeUploaderSpace()
        )

        coordinator.openPlayback("")

        #expect(coordinator.currentPlaybackBVID == nil)
        #expect(events.isEmpty)
    }
}
