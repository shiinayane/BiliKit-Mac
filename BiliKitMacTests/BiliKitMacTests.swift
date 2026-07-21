import BiliApplication
import BiliAuthFeature
import BiliGuestFeature
import BiliHistoryFeature
import Testing
@testable import BiliKit

struct BiliKitMacTests {
    @Test
    @MainActor
    func liveEnvironmentBuildsIdleGuestViewModels() {
        let environment = AppEnvironment.live

        let feedModel = environment.makeFeedViewModel()
        let videoModel = environment.makeVideoViewModel()
        let authenticationModel = environment.makeAuthenticationViewModel()
        let historyModel = environment.makeWatchHistoryViewModel()

        #expect(feedModel.state == .idle)
        #expect(videoModel.state == .idle)
        #expect(authenticationModel.state == .signedOut)
        #expect(historyModel.state == .idle)
    }
}
