import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import Testing

@testable import BiliKit

struct BiliKitMacTests {
    @Test
    @MainActor
    func liveEnvironmentBuildsIdleGuestViewModels() {
        let environment = AppEnvironment.live()

        let browseModel = environment.makeBrowseViewModel()
        let videoModel = environment.makeVideoViewModel()
        let subtitleModel = environment.makeSubtitleViewModel()
        let authenticationModel = environment.makeAuthenticationViewModel()
        let historyModel = environment.makeWatchHistoryViewModel()

        #expect(browseModel.state == .idle)
        #expect(videoModel.state == .idle)
        #expect(subtitleModel.state == .idle)
        #expect(authenticationModel.state == .signedOut)
        #expect(historyModel.state == .idle)
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
}
