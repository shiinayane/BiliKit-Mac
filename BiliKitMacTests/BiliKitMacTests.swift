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
}
