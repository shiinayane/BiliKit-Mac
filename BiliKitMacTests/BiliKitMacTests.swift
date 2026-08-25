import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import BiliModels
import Testing

@testable import BiliKit

struct BiliKitMacTests {
    @Test
    @MainActor
    func liveEnvironmentBuildsIdleGuestViewModels() {
        let environment = AppEnvironment.live()

        let browseModel = environment.makeBrowseViewModel()
        let videoModel = environment.makeVideoViewModel()
        let authenticationModel = environment.makeAuthenticationViewModel()
        let historyModel = environment.makeWatchHistoryViewModel()

        #expect(browseModel.state == .idle)
        #expect(videoModel.state == .idle)
        #expect(authenticationModel.state == .signedOut)
        #expect(historyModel.state == .idle)
        #expect(environment.nativeSubtitlesEnabled)
    }

    @Test
    @MainActor
    func windowOwnerRetainsPlaybackPreferencesObservation() {
        weak var weakController: PlaybackPreferencesController?
        var owner: AppWindowOwner?

        do {
            let environment = AppEnvironment.live()
            weakController = environment.playbackPreferencesController
            owner = AppWindowOwner(environment: environment)
        }

        #expect(weakController != nil)
        withExtendedLifetime(owner) {}
        owner = nil
        #expect(weakController == nil)
    }

    @Test
    @MainActor
    func watchProgressTargetRequiresExactPresentedIdentity() throws {
        let identity = PlaybackItemIdentity(bvid: "BV1TARGETFIXTURE", cid: 22)
        let loadIntent = PlaybackLoadIntent()

        let target = try #require(
            WatchProgressTargetResolution.resolve(
                aid: 11,
                bvid: identity.bvid,
                cid: identity.cid,
                identity: identity,
                loadIntent: loadIntent
            )
        )
        #expect(target.aid == 11)
        #expect(target.identity == identity)
        #expect(target.loadIntent == loadIntent)
        #expect(
            WatchProgressTargetResolution.resolve(
                aid: 11,
                bvid: "BV1REPLACEMENTFIXTURE",
                cid: identity.cid,
                identity: identity,
                loadIntent: loadIntent
            ) == nil
        )
        #expect(
            WatchProgressTargetResolution.resolve(
                aid: 11,
                bvid: identity.bvid,
                cid: identity.cid + 1,
                identity: identity,
                loadIntent: loadIntent
            ) == nil
        )
        #expect(
            WatchProgressTargetResolution.resolve(
                aid: nil,
                bvid: identity.bvid,
                cid: identity.cid,
                identity: identity,
                loadIntent: loadIntent
            ) == nil
        )
    }

    @Test
    @MainActor
    func accountCoordinatorOwnsOneProcessWatchProgressWriter() async {
        let coordinator = AccountSessionCoordinator()
        let base = EmptyWatchProgressRepository()
        let transport = WatchProgressTransportInvalidator()
        var factoryCount = 0

        for _ in 0..<2 {
            _ = coordinator.resolveWatchProgressRepository {
                factoryCount += 1
                return (base, transport)
            }
        }
        #expect(factoryCount == 1)

        await coordinator.invalidateAuthenticatedSession()
        #expect(await transport.invalidationCount == 1)
    }
}

private actor EmptyWatchProgressRepository: WatchProgressRepository {
    func report(_ progress: WatchProgressReport) {}
}

private actor WatchProgressTransportInvalidator: AuthenticatedSessionInvalidating {
    private(set) var invalidationCount = 0

    func invalidateAuthenticatedSession() {
        invalidationCount += 1
    }
}
