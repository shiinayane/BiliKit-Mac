import BiliApplication
import BiliAuthFeature
import BiliModels
import BiliVideoDetailFeature
import Foundation
import Observation
import Synchronization
import Testing

@testable import BiliKit

@Suite(.timeLimit(.minutes(1)))
struct AppNavigationCoordinatorTests {
    @Test
    @MainActor
    func accountSessionCoordinatorPublishesOnlyResolvedProcessChanges() {
        let coordinator = AccountSessionCoordinator()

        coordinator.publish(.unresolved)
        #expect(coordinator.generation == 0)
        #expect(coordinator.scope == .unresolved)

        coordinator.publish(.signedIn(accountID: 1))
        #expect(coordinator.generation == 1)
        #expect(coordinator.scope == .signedIn(accountID: 1))

        coordinator.publish(.signedIn(accountID: 1))
        #expect(coordinator.generation == 1)

        coordinator.publish(.signedOut)
        #expect(coordinator.generation == 2)
        #expect(coordinator.scope == .signedOut)
    }

    @Test
    @MainActor
    func accountSessionCoordinatorInvalidatesEveryRegisteredWindowSession() async {
        let coordinator = AccountSessionCoordinator()
        let first = RecordingSessionInvalidator()
        let second = RecordingSessionInvalidator()
        let closed = RecordingSessionInvalidator()
        _ = coordinator.registerSessionInvalidator(first)
        _ = coordinator.registerSessionInvalidator(second)
        let closedRegistration = coordinator.registerSessionInvalidator(closed)
        coordinator.unregisterSessionInvalidator(closedRegistration)

        await coordinator.invalidateAuthenticatedSession()

        #expect(await first.invalidationCount == 1)
        #expect(await second.invalidationCount == 1)
        #expect(await closed.invalidationCount == 0)
    }

    @Test
    @MainActor
    func sessionRegistrationDoesNotInvalidateObservedAccountState() {
        let coordinator = AccountSessionCoordinator()
        let invalidator = RecordingSessionInvalidator()
        let observationChanged = Mutex(false)

        withObservationTracking {
            _ = coordinator.generation
            _ = coordinator.scope
        } onChange: {
            observationChanged.withLock { $0 = true }
        }

        let registrationID = coordinator.registerSessionInvalidator(invalidator)
        coordinator.unregisterSessionInvalidator(registrationID)

        #expect(!observationChanged.withLock { $0 })
    }

    @Test
    func historyOwnershipTracksAccountIDWithoutFollowingProfileChanges() {
        let first = AccountIdentity(id: 1, displayName: "账号一", avatarURL: nil)
        let renamedFirst = AccountIdentity(id: 1, displayName: "新昵称", avatarURL: nil)
        let second = AccountIdentity(id: 2, displayName: "账号二", avatarURL: nil)

        let unresolved = AccountSessionScope.unresolved
        let signedOut = AccountSessionScope.signedOut
        let unknown = AccountSessionScope.signedIn(accountID: nil)
        let firstScope = AccountSessionScope.signedIn(accountID: first.id)
        let renamedScope = AccountSessionScope.signedIn(accountID: renamedFirst.id)
        let secondScope = AccountSessionScope.signedIn(accountID: second.id)

        #expect(!AccountSessionScope.isResolvedChange(from: unresolved, to: unknown))
        #expect(AccountSessionScope.isResolvedChange(from: signedOut, to: unknown))
        #expect(AccountSessionScope.isResolvedChange(from: unknown, to: firstScope))
        #expect(!AccountSessionScope.isResolvedChange(from: firstScope, to: renamedScope))
        #expect(AccountSessionScope.isResolvedChange(from: firstScope, to: secondScope))
        #expect(AccountSessionScope.isResolvedChange(from: secondScope, to: signedOut))
    }

    @Test(arguments: AppTab.allCases)
    @MainActor
    func nativeBackReturnsEachSourceInOnePop(source: AppTab) {
        var stopCount = 0
        let coordinator = AppNavigationCoordinator(
            startPlayback: { _ in },
            stopPlayback: { stopCount += 1 },
            uploaderSpace: makeUploaderSpace()
        )
        coordinator.selectedTab = source

        coordinator.openPlayback("BV1Source")
        #expect(coordinator.playbackPath.count == 1)
        coordinator.playbackPath.removeLast()
        coordinator.playbackPath.removeAll()

        #expect(coordinator.selectedTab == source)
        #expect(coordinator.playbackPath.isEmpty)
        #expect(coordinator.currentPlaybackBVID == nil)
        #expect(stopCount == 1)
    }

    @Test
    @MainActor
    func replacementKeepsSurfaceAndSourceWhileOrderingSideEffects() {
        var events: [String] = []
        let coordinator = AppNavigationCoordinator(
            startPlayback: { events.append("start:\($0.bvid)") },
            stopPlayback: { events.append("stop") },
            uploaderSpace: makeUploaderSpace()
        )
        coordinator.selectedTab = .search

        coordinator.openPlayback("BV1RouteA")
        let surfaceID = coordinator.playbackPath.first?.surfaceID
        coordinator.openPlayback("BV1RouteB")
        coordinator.openPlayback("BV1RouteC")

        #expect(coordinator.playbackPath.count == 1)
        #expect(coordinator.playbackPath.first?.surfaceID == surfaceID)
        #expect(coordinator.currentPlaybackBVID == "BV1RouteC")
        #expect(coordinator.selectedTab == .search)
        #expect(
            events == [
                "start:BV1RouteA",
                "start:BV1RouteB",
                "start:BV1RouteC"
            ]
        )
    }

    @Test
    @MainActor
    func nonemptyPathWriteCannotForgeOrReplacePlayback() {
        var events: [String] = []
        let coordinator = AppNavigationCoordinator(
            startPlayback: { events.append("start:\($0.bvid)") },
            stopPlayback: { events.append("stop") },
            uploaderSpace: makeUploaderSpace()
        )
        let forgedDestination = PlaybackDestination(surfaceID: UUID())

        coordinator.playbackPath = [forgedDestination]
        #expect(coordinator.playbackPath.isEmpty)
        #expect(coordinator.currentPlaybackBVID == nil)

        coordinator.openPlayback("BV1Actual")
        let actualDestination = coordinator.playbackPath.first
        coordinator.playbackPath = [forgedDestination]

        #expect(coordinator.playbackPath.count == 1)
        #expect(coordinator.playbackPath.first == actualDestination)
        #expect(coordinator.currentPlaybackBVID == "BV1Actual")
        #expect(events == ["start:BV1Actual"])
    }

    @Test
    @MainActor
    func reopeningCurrentPlaybackDoesNotDuplicateLoad() {
        var startCount = 0
        let coordinator = AppNavigationCoordinator(
            startPlayback: { _ in startCount += 1 },
            stopPlayback: {},
            uploaderSpace: makeUploaderSpace()
        )

        coordinator.openPlayback("BV1SameA")
        coordinator.openPlayback("BV1SameA")

        #expect(startCount == 1)
        #expect(coordinator.playbackPath.count == 1)
    }

    @Test
    @MainActor
    func sameBVIDDifferentCIDIsANewAtomicSelectionIntent() {
        var intents: [PlaybackSelectionIntent] = []
        let coordinator = AppNavigationCoordinator(
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
        #expect(coordinator.playbackPath.count == 1)
    }

    @Test
    @MainActor
    func retryKeepsSurfaceAndMediaIdentity() {
        var intents: [PlaybackSelectionIntent] = []
        let coordinator = AppNavigationCoordinator(
            startPlayback: { intents.append($0) },
            stopPlayback: {},
            uploaderSpace: makeUploaderSpace()
        )

        coordinator.openPlayback(
            PlaybackSelectionIntent(bvid: "BV1RetryA", preferredCID: 202)
        )
        let destination = coordinator.playbackPath.first
        coordinator.retryPlayback()

        #expect(coordinator.playbackPath.first == destination)
        #expect(coordinator.currentPlaybackBVID == "BV1RetryA")
        #expect(intents.map(\.preferredCID) == [202, 202])
    }

    @Test
    @MainActor
    func selectingAnotherSourceClosesPlaybackExactlyOnce() {
        var stopCount = 0
        let coordinator = AppNavigationCoordinator(
            startPlayback: { _ in },
            stopPlayback: { stopCount += 1 },
            uploaderSpace: makeUploaderSpace()
        )

        coordinator.openPlayback("BV1SidebarA")
        coordinator.selectedTab = .search
        coordinator.selectedTab = .search

        #expect(coordinator.selectedTab == .search)
        #expect(coordinator.playbackPath.isEmpty)
        #expect(coordinator.currentPlaybackBVID == nil)
        #expect(stopCount == 1)
    }

    @Test
    @MainActor
    func windowClosureIsIdempotentAndResetsWindowState() {
        var stopCount = 0
        let coordinator = AppNavigationCoordinator(
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
        #expect(coordinator.playbackPath.isEmpty)
        #expect(coordinator.currentPlaybackBVID == nil)
    }

    @Test
    @MainActor
    func authenticationChangeClosesPlaybackWithoutLosingSourceContext() {
        var stopCount = 0
        let coordinator = AppNavigationCoordinator(
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
        #expect(coordinator.playbackPath.isEmpty)
        #expect(coordinator.currentPlaybackBVID == nil)
    }

    @Test
    @MainActor
    func choosingFromTheContextLayerKeepsIt() {
        let space = makeUploaderSpace()
        var contextOpenAtStart: [Bool] = []
        let coordinator = AppNavigationCoordinator(
            startPlayback: { _ in contextOpenAtStart.append(space.owner != nil) },
            stopPlayback: {},
            uploaderSpace: space
        )
        coordinator.openPlayback("BV1Source")
        coordinator.openUploaderSpace(owner: VideoOwner(id: 42, name: "UP"))

        coordinator.openPlaybackFromContextLayer("BV1FromSpace")

        #expect(contextOpenAtStart == [false, true])
        #expect(coordinator.isContextLayerOpen)
        #expect(coordinator.currentPlaybackBVID == "BV1FromSpace")
    }

    /// 其他入口换视频先关闭上下文层再开始播放；重新打开正在播放的视频也关闭它。
    @Test
    @MainActor
    func otherEntriesCloseTheContextLayerEvenForTheCurrentVideo() {
        let space = makeUploaderSpace()
        var events: [String] = []
        let coordinator = AppNavigationCoordinator(
            startPlayback: { events.append("start:\($0.bvid) context:\(space.owner != nil)") },
            stopPlayback: { events.append("stop") },
            uploaderSpace: space
        )
        coordinator.openPlayback("BV1Source")
        events.removeAll()

        coordinator.openUploaderSpace(owner: VideoOwner(id: 42, name: "UP"))
        coordinator.openPlayback("BV1Related")
        #expect(!coordinator.isContextLayerOpen)

        coordinator.openUploaderSpace(owner: VideoOwner(id: 42, name: "UP"))
        coordinator.openPlayback("BV1Related")

        #expect(!coordinator.isContextLayerOpen)
        #expect(events == ["start:BV1Related context:false"])
    }

    /// 关闭播放时上下文层只关一次：之后重复的关闭播放不再动它。
    @Test(arguments: ["tab", "authentication", "back"])
    @MainActor
    func closingPlaybackClosesTheContextLayerOnce(trigger: String) async {
        let space = makeUploaderSpace()
        var events: [String] = []
        let coordinator = AppNavigationCoordinator(
            startPlayback: { _ in },
            stopPlayback: { events.append("stop context:\(space.owner != nil)") },
            uploaderSpace: space
        )
        coordinator.openPlayback("BV1Source")
        coordinator.openUploaderSpace(owner: VideoOwner(id: 42, name: "UP"))
        coordinator.openPlaybackFromContextLayer("BV1FromSpace")
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
            coordinator.playbackPath.removeAll()
        }
        countNextClose()
        coordinator.closePlaybackForAuthenticationChange()

        #expect(!coordinator.isContextLayerOpen)
        #expect(closeCount.withLock { $0 } == 1)
        #expect(events == ["stop context:false"])
    }

    /// 空间链接只有 MID：在右栏空间层打开，并补取名片。
    @Test
    @MainActor
    func memberIDLinksOpenTheSpace() async throws {
        let profiles = UploaderProfileRepositoryStub(holdsRequests: true)
        let space = makeUploaderSpace(profiles: profiles)
        let coordinator = AppNavigationCoordinator(
            startPlayback: { _ in },
            stopPlayback: {},
            uploaderSpace: space
        )

        coordinator.openUploaderSpace(ownerID: 42)

        #expect(space.owner?.id == 42)
        #expect(coordinator.isContextLayerOpen)
        // 只有 MID 的入口会补取名片：放行它，不留下挂起的请求。
        try await profiles.waitForRequest()
        await profiles.releaseLateResult()
    }

    @Test
    @MainActor
    func emptyBVIDDoesNotCreatePlaybackState() {
        var events: [String] = []
        let coordinator = AppNavigationCoordinator(
            startPlayback: { events.append("start:\($0.bvid)") },
            stopPlayback: { events.append("stop") },
            uploaderSpace: makeUploaderSpace()
        )

        coordinator.openPlayback("")

        #expect(coordinator.playbackPath.isEmpty)
        #expect(coordinator.currentPlaybackBVID == nil)
        #expect(events.isEmpty)
    }
}
