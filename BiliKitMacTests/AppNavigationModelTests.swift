import Testing

@testable import BiliKit

struct AppNavigationModelTests {
    @Test
    @MainActor
    func playbackReturnAndSecondSelectionHaveOneSideEffectOwner() {
        var events: [String] = []
        let model = AppNavigationModel(
            startPlayback: { events.append("start:\($0)") },
            stopPlayback: { events.append("stop") }
        )

        model.openPlayback("BV1RouteA")
        model.playbackPath.removeLast()
        model.openPlayback("BV1RouteB")

        #expect(
            events == [
                "start:BV1RouteA",
                "stop",
                "start:BV1RouteB",
            ]
        )
        #expect(
            model.playbackPath == [
                PlaybackDestination(bvid: "BV1RouteB")
            ]
        )
    }

    @Test
    @MainActor
    func returnRestoresSearchSourceAndQueryWithoutRestartingPlayback() {
        var startCount = 0
        var stopCount = 0
        let model = AppNavigationModel(
            startPlayback: { _ in startCount += 1 },
            stopPlayback: { stopCount += 1 }
        )
        model.selectedSection = .search
        model.searchQuery = "手写搜索词"

        model.openPlayback("BV1SearchA")
        model.playbackPath.removeLast()

        #expect(model.selectedSection == .search)
        #expect(model.playbackPath.isEmpty)
        #expect(model.searchQuery == "手写搜索词")
        #expect(startCount == 1)
        #expect(stopCount == 1)
    }

    @Test
    @MainActor
    func closingWindowStopsPlaybackOnceAndResetsNativeNavigation() {
        var stopCount = 0
        let model = AppNavigationModel(
            startPlayback: { _ in },
            stopPlayback: { stopCount += 1 }
        )

        model.openPlayback("BV1CloseA")
        model.closeWindow()
        model.closeWindow()

        #expect(stopCount == 1)
        #expect(model.selectedSection == .popular)
        #expect(model.playbackPath.isEmpty)
    }

    @Test
    @MainActor
    func selectingAnotherSidebarSectionPopsPlaybackAndStopsOnce() {
        var stopCount = 0
        let model = AppNavigationModel(
            startPlayback: { _ in },
            stopPlayback: { stopCount += 1 }
        )

        model.openPlayback("BV1SidebarA")
        model.selectedSection = .search

        #expect(stopCount == 1)
        #expect(model.selectedSection == .search)
        #expect(model.playbackPath.isEmpty)
    }

    @Test
    @MainActor
    func reopeningCurrentPlaybackDoesNotDuplicateLoad() {
        var startCount = 0
        let model = AppNavigationModel(
            startPlayback: { _ in startCount += 1 },
            stopPlayback: {}
        )

        model.openPlayback("BV1SameA")
        model.openPlayback("BV1SameA")

        #expect(startCount == 1)
    }

    @Test
    @MainActor
    func playbackRetryUsesTheAppOwnerWithoutChangingPath() {
        var events: [String] = []
        let model = AppNavigationModel(
            startPlayback: { events.append("start:\($0)") },
            stopPlayback: { events.append("stop") }
        )

        model.openPlayback("BV1RetryA")
        model.retryPlayback()

        #expect(
            events == [
                "start:BV1RetryA",
                "start:BV1RetryA",
            ]
        )
        #expect(
            model.playbackPath == [
                PlaybackDestination(bvid: "BV1RetryA")
            ]
        )
    }

    @Test
    @MainActor
    func historySelectionRemainsTheSourceWhilePlaybackIsPushed() {
        var stopCount = 0
        let model = AppNavigationModel(
            startPlayback: { _ in },
            stopPlayback: { stopCount += 1 }
        )
        model.selectedSection = .history
        model.openPlayback("BV1HistoryA")

        #expect(
            model.playbackPath == [
                PlaybackDestination(bvid: "BV1HistoryA")
            ]
        )
        #expect(model.selectedSection == .history)
        #expect(stopCount == 0)
    }

    @Test
    @MainActor
    func nativePathPopStopsPlaybackExactlyOnce() {
        var stopCount = 0
        let model = AppNavigationModel(
            startPlayback: { _ in },
            stopPlayback: { stopCount += 1 }
        )
        model.openPlayback("BV1NativeBack")

        model.playbackPath.removeLast()
        model.playbackPath.removeAll()

        #expect(stopCount == 1)
        #expect(model.playbackPath.isEmpty)
    }
}
