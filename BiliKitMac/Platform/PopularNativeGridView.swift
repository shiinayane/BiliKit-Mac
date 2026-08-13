import BiliBrowseFeature
import BiliModels
import SwiftUI

struct PopularNativeGridView: View {
    @State private var imageOwner = NativeVideoImagePipelineOwner()
    let videos: [PopularVideo]
    @Binding var scrollOffsetY: CGFloat
    let onSelect: (String) -> Void

    var body: some View {
        NativeVideoGridView(
            items: Self.makePresentations(videos),
            scrollOffsetY: $scrollOffsetY,
            accessibilityLabel: "热门视频",
            tailState: .end,
            imagePipeline: imageOwner.pipeline,
            onNearEnd: {},
            onSelect: onSelect
        )
    }

    static func makePresentations(
        _ videos: [PopularVideo]
    ) -> [NativeVideoCardPresentation] {
        var seenBVIDs: Set<String> = []
        return videos.compactMap { video in
            guard seenBVIDs.insert(video.bvid).inserted else { return nil }
            let presentation = PopularVideoCardPresentation(video: video)
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
                accessibilityLabel: [
                    presentation.title,
                    presentation.ownerName,
                    "播放 \(presentation.viewCountText)",
                    "弹幕 \(presentation.danmakuCountText)",
                    "时长 \(presentation.durationText)",
                ].joined(separator: "，")
            )
        }
    }
}
