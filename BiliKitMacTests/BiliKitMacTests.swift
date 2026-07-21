import BiliApplication
import BiliAuthFeature
import BiliGuestFeature
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

        #expect(feedModel.state == .idle)
        #expect(videoModel.state == .idle)
        #expect(authenticationModel.state == .signedOut)
    }
}
