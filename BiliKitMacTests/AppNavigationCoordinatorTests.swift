import Testing

@testable import BiliKit

struct AppNavigationCoordinatorTests {
    @Test
    @MainActor
    func playbackReturnAndSecondPlaybackHaveOneSideEffectOwner() {
        var events: [String] = []
        let coordinator = AppNavigationCoordinator(
            startPlayback: { events.append("start:\($0)") },
            stopPlayback: { events.append("stop") }
        )

        coordinator.openPlayback("BV1RouteA")
        coordinator.playbackPath.removeLast()
        coordinator.openPlayback("BV1RouteB")

        #expect(
            events == [
                "start:BV1RouteA",
                "stop",
                "start:BV1RouteB",
            ]
        )
        #expect(
            coordinator.playbackPath == [
                PlaybackDestination(bvid: "BV1RouteB")
            ]
        )
    }

    @Test
    @MainActor
    func returnRestoresSearchSourceAndQueryWithoutRestartingPlayback() {
        var startCount = 0
        var stopCount = 0
        let coordinator = AppNavigationCoordinator(
            startPlayback: { _ in startCount += 1 },
            stopPlayback: { stopCount += 1 }
        )
        coordinator.selectedTab = .search
        coordinator.searchDraft = "手写搜索词"

        coordinator.openPlayback("BV1SearchA")
        coordinator.playbackPath.removeLast()

        #expect(coordinator.selectedTab == .search)
        #expect(coordinator.playbackPath.isEmpty)
        #expect(coordinator.searchDraft == "手写搜索词")
        #expect(startCount == 1)
        #expect(stopCount == 1)
    }

    @Test
    @MainActor
    func closingWindowStopsPlaybackOnceAndResetsNativeNavigation() {
        var stopCount = 0
        let coordinator = AppNavigationCoordinator(
            startPlayback: { _ in },
            stopPlayback: { stopCount += 1 }
        )

        coordinator.openPlayback("BV1CloseA")
        coordinator.resetForWindowClosure()
        coordinator.resetForWindowClosure()

        #expect(stopCount == 1)
        #expect(coordinator.selectedTab == .popular)
        #expect(coordinator.playbackPath.isEmpty)
    }

    @Test
    @MainActor
    func selectingAnotherTabPopsPlaybackAndStopsOnce() {
        var stopCount = 0
        let coordinator = AppNavigationCoordinator(
            startPlayback: { _ in },
            stopPlayback: { stopCount += 1 }
        )

        coordinator.openPlayback("BV1SidebarA")
        coordinator.selectedTab = .search

        #expect(stopCount == 1)
        #expect(coordinator.selectedTab == .search)
        #expect(coordinator.playbackPath.isEmpty)
    }

    @Test
    @MainActor
    func reopeningCurrentPlaybackDoesNotDuplicateLoad() {
        var startCount = 0
        let coordinator = AppNavigationCoordinator(
            startPlayback: { _ in startCount += 1 },
            stopPlayback: {}
        )

        coordinator.openPlayback("BV1SameA")
        coordinator.openPlayback("BV1SameA")

        #expect(startCount == 1)
    }

    @Test
    @MainActor
    func playbackRetryUsesTheAppOwnerWithoutChangingPath() {
        var events: [String] = []
        let coordinator = AppNavigationCoordinator(
            startPlayback: { events.append("start:\($0)") },
            stopPlayback: { events.append("stop") }
        )

        coordinator.openPlayback("BV1RetryA")
        coordinator.retryPlayback()

        #expect(
            events == [
                "start:BV1RetryA",
                "start:BV1RetryA",
            ]
        )
        #expect(
            coordinator.playbackPath == [
                PlaybackDestination(bvid: "BV1RetryA")
            ]
        )
    }

    @Test
    @MainActor
    func historyTabRemainsTheSourceWhilePlaybackIsPushed() {
        var stopCount = 0
        let coordinator = AppNavigationCoordinator(
            startPlayback: { _ in },
            stopPlayback: { stopCount += 1 }
        )
        coordinator.selectedTab = .history
        coordinator.openPlayback("BV1HistoryA")

        #expect(
            coordinator.playbackPath == [
                PlaybackDestination(bvid: "BV1HistoryA")
            ]
        )
        #expect(coordinator.selectedTab == .history)
        #expect(stopCount == 0)
    }

    @Test
    @MainActor
    func nativePathPopStopsPlaybackExactlyOnce() {
        var stopCount = 0
        let coordinator = AppNavigationCoordinator(
            startPlayback: { _ in },
            stopPlayback: { stopCount += 1 }
        )
        coordinator.openPlayback("BV1NativeBack")

        coordinator.playbackPath.removeLast()
        coordinator.playbackPath.removeAll()

        #expect(stopCount == 1)
        #expect(coordinator.playbackPath.isEmpty)
    }
}
