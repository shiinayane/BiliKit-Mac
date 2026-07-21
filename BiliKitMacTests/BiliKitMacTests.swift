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

        #expect(feedModel.state == .idle)
        #expect(videoModel.state == .idle)
    }
}
