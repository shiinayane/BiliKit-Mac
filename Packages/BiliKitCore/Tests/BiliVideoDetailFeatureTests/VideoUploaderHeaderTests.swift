import BiliModels
import BiliUI
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// UP 主行的展示值：空白签名隐藏、名字有兜底；粉丝数用紧凑计数、投稿数照原数，缺哪项只显示另一项，都缺时隐藏，加载中占位。
struct VideoUploaderHeaderTests {
    @Test
    func statsShowWhicheverCountsTheCardGave() {
        func stats(_ profile: UploaderProfile) -> VideoUploaderLineContent {
            VideoUploaderHeaderContent(
                owner: VideoOwner(id: 42, name: "UP"),
                profileState: .loaded(profile)
            ).stats
        }
        let followers = VideoDetailFeatureStrings.localized(
            "\(VideoMetadataFormatting.compactCount(123_456))粉丝"
        )
        let videos = VideoDetailFeatureStrings.localized("\(Int64(78)) 个投稿")

        #expect(
            stats(UploaderProfile(followerCount: 123_456, videoCount: 78))
                == .text("\(followers) · \(videos)")
        )
        #expect(stats(UploaderProfile(followerCount: 123_456)) == .text(followers))
        #expect(stats(UploaderProfile(videoCount: 78)) == .text(videos))
        #expect(stats(UploaderProfile()) == .hidden)
        let loading = VideoUploaderHeaderContent(
            owner: VideoOwner(id: 42, name: "UP"),
            profileState: .loading
        )
        #expect(loading.stats == .loading)
    }

    @Test
    func hidesBlankSignatureAndProvidesNameFallback() {
        let content = VideoUploaderHeaderContent(
            owner: VideoOwner(id: 42, name: " \n "),
            profileState: .loaded(UploaderProfile(signature: "  \t\n  "))
        )

        #expect(!content.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(content.signature == .hidden)
    }
}
