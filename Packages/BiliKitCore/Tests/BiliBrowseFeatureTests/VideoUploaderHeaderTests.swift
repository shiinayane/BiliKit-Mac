import BiliModels
import Foundation
import Testing

@testable import BiliBrowseFeature

struct VideoUploaderHeaderTests {
    @Test
    func hidesBlankSignatureAndProvidesNameFallback() {
        let content = VideoUploaderHeaderContent(
            owner: VideoOwner(
                id: 42,
                name: " \n ",
                signature: "  \t\n  "
            )
        )

        #expect(!content.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(content.signature == .hidden)
    }
}
