import BiliBrowseFeature
import BiliModels
import SwiftUI

struct RecommendedNativeGridView: View {
    @State private var imageOwner = NativeVideoImagePipelineOwner()
    let videos: [RecommendedVideo]
    @Binding var scrollOffsetY: CGFloat
    let canLoadMore: Bool
    let tailIdentity: String?
    let isLoading: Bool
    @Binding var scrollReset: NativeVideoGridScrollResetState
    let onNearEnd: () -> Void
    let onSelect: (String) -> Void

    var body: some View {
        NativeVideoGridView(
            items: Self.makePresentations(videos),
            scrollOffsetY: $scrollOffsetY,
            accessibilityLabel: "首页推荐视频",
            tailState: NativeVideoGridTailState(
                canLoadMore: canLoadMore,
                tailIdentity: tailIdentity,
                isLoading: isLoading
            ),
            scrollReset: $scrollReset,
            imagePipeline: imageOwner.pipeline,
            onNearEnd: onNearEnd,
            onSelect: onSelect
        )
    }

    static func makePresentations(
        _ videos: [RecommendedVideo]
    ) -> [NativeVideoCardPresentation] {
        var seenBVIDs: Set<String> = []
        return videos.compactMap { video in
            guard seenBVIDs.insert(video.bvid).inserted else { return nil }
            let presentation = RecommendedVideoCardPresentation(video: video)
            return NativeVideoCardPresentation(
                id: presentation.bvid,
                title: presentation.title,
                coverURL: presentation.coverURL,
                avatarURL: presentation.avatarURL,
                showsAvatar: true,
                coverMetrics: [
                    NativeVideoCardMetric(
                        text: presentation.viewCountText,
                        systemImage: "play.fill"
                    ),
                    NativeVideoCardMetric(
                        text: presentation.danmakuCountText,
                        systemImage: "text.bubble.fill"
                    ),
                ],
                coverTrailingText: presentation.durationText,
                footerLeadingText: presentation.footerText,
                footerTrailingText: presentation.recommendationReason,
                footerTrailingStyle: presentation.recommendationReason == nil
                    ? .plain
                    : .brandOutlinedCapsule,
                accessibilityLabel: [
                    presentation.title,
                    presentation.ownerName,
                    "播放 \(presentation.viewCountText)",
                    "弹幕 \(presentation.danmakuCountText)",
                    "时长 \(presentation.durationText)",
                    presentation.recommendationReason.map { "推荐理由 \($0)" },
                ].compactMap { $0 }.joined(separator: "，")
            )
        }
    }
}
