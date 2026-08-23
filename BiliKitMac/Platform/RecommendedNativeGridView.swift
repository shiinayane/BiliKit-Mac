import BiliBrowseFeature
import BiliModels
import Foundation
import SwiftUI

struct RecommendedNativeGridView: View {
    @State private var imageOwner = NativeVideoImagePipelineOwner()
    @Environment(\.locale) private var locale
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
            items: Self.makePresentations(videos, locale: locale),
            scrollOffsetY: $scrollOffsetY,
            accessibilityLabel: AppStrings.localized("首页推荐视频", locale: locale),
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
        _ videos: [RecommendedVideo],
        locale: Locale = .current
    ) -> [NativeVideoCardPresentation] {
        var seenBVIDs: Set<String> = []
        return videos.compactMap { video in
            guard seenBVIDs.insert(video.bvid).inserted else { return nil }
            let presentation = RecommendedVideoCardPresentation(video: video, locale: locale)
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
                accessibilityLabel: ListFormatter.localizedString(
                    byJoining: [
                        presentation.title,
                        presentation.ownerName,
                        AppStrings.localized("播放 \(presentation.viewCountText)", locale: locale),
                        AppStrings.localized("弹幕 \(presentation.danmakuCountText)", locale: locale),
                        AppStrings.localized("时长 \(presentation.durationText)", locale: locale),
                        presentation.recommendationReason.map {
                            AppStrings.localized("推荐理由 \($0)", locale: locale)
                        },
                    ].compactMap { $0 }
                )
            )
        }
    }
}
