import BiliModels
import Foundation
import Testing
@testable import BiliBrowseFeature

struct VideoUploaderHeaderTests {
    @Test
    func normalizesNameAndSignatureForSingleLinePresentation() {
        let avatarURL = URL(string: "https://example.com/avatar.webp")
        let content = VideoUploaderHeaderContent(
            owner: VideoOwner(
                id: 42,
                name: "  示例 UP 主  ",
                avatarURL: avatarURL,
                signature: "  用影像记录生活\n也记录技术  "
            )
        )

        #expect(content.name == "示例 UP 主")
        #expect(content.avatarURL == avatarURL)
        #expect(content.signature == .text("用影像记录生活 也记录技术"))
    }

    @Test
    func hidesBlankSignatureAndProvidesNameFallback() {
        let content = VideoUploaderHeaderContent(
            owner: VideoOwner(
                id: 42,
                name: " \n ",
                signature: "  \t\n  "
            )
        )

        #expect(content.name == "未知 UP 主")
        #expect(content.signature == .hidden)
    }

    @Test
    func representsIndependentSignatureLoadingWithoutReplacingOwner() {
        let content = VideoUploaderHeaderContent(
            owner: VideoOwner(
                id: 42,
                name: "示例 UP 主",
                avatarURL: URL(string: "https://example.com/avatar.webp")
            ),
            signatureState: .loading
        )

        #expect(content.name == "示例 UP 主")
        #expect(content.avatarURL != nil)
        #expect(content.signature == .loading)
    }
}
