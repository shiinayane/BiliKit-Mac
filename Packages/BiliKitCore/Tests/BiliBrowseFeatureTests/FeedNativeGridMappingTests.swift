import BiliModels
import BiliVideoCollectionUI
import Foundation
import Testing

@testable import BiliBrowseFeature

/// 首页推荐映射到原生卡片时：推荐理由只在存在时显示为品牌描边胶囊，读屏标签与卡片呈现一致。
struct FeedNativeGridMappingTests {
    @Test @MainActor
    func recommendationMappingUsesBrandCapsuleOnlyWhenReasonExists() throws {
        let video = RecommendedVideo(
            bvid: "BV-rcmd-stable",
            title: "首页推荐卡片",
            coverURL: nil,
            owner: VideoOwner(id: 1, name: "作者"),
            viewCount: 10,
            danmakuCount: 2,
            durationSeconds: 125,
            publishedAt: Date(timeIntervalSince1970: 0),
            recommendationReason: "正在流行"
        )

        let content = RecommendedNativeGridView.makePresentation(video, isDisliked: false)
        #expect(content.footerTrailingText == "正在流行")
        #expect(content.footerTrailingStyle == .brandOutlinedCapsule)
        #expect(
            content.accessibilityLabel
                == RecommendedVideoCardPresentation(video: video).accessibilityLabel
        )

        let withoutReason = RecommendedVideo(
            bvid: "BV-rcmd-plain",
            title: video.title,
            coverURL: nil,
            owner: video.owner,
            viewCount: video.viewCount,
            danmakuCount: video.danmakuCount,
            durationSeconds: video.durationSeconds,
            publishedAt: video.publishedAt,
            recommendationReason: nil
        )
        #expect(content.coverMetrics.count == 2)
        let plain = RecommendedNativeGridView.makePresentation(withoutReason, isDisliked: false)
        #expect(plain.footerTrailingText == nil)
        #expect(plain.footerTrailingStyle == .plain)
    }

    /// 解析不出的计数不在封面上占位。
    @Test @MainActor
    func recommendationMappingOmitsUnparsedCounts() {
        let video = RecommendedVideo(
            bvid: "BV-rcmd-counts",
            title: "首页推荐卡片",
            coverURL: nil,
            owner: VideoOwner(id: 1, name: "作者"),
            viewCount: 10,
            danmakuCount: nil,
            durationSeconds: 125,
            publishedAt: nil,
            recommendationReason: nil
        )

        let content = RecommendedNativeGridView.makePresentation(video, isDisliked: false)
        #expect(content.coverMetrics.map(\.systemImage) == ["play.fill"])
    }
}
