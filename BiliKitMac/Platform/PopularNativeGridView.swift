import BiliBrowseFeature
import BiliModels
import Foundation
import SwiftUI

struct PopularNativeGridView: View {
    @Environment(\.locale) private var locale
    let content: LoadedFeedContent<PopularVideo>
    @Binding var scrollOffsetY: CGFloat
    @Binding var scrollReset: NativeVideoGridScrollResetState
    let imagePipeline: NativeVideoImagePipeline

    var body: some View {
        NativeVideoGridView(
            items: Self.makePresentations(content.items, locale: locale),
            scrollOffsetY: $scrollOffsetY,
            accessibilityLabel: AppStrings.localized("热门视频", locale: locale),
            tailState: NativeVideoGridTailState(
                canLoadMore: content.canLoadMore,
                tailIdentity: content.tailIdentity,
                isLoading: content.isLoadingMore
            ),
            scrollReset: $scrollReset,
            imagePipeline: imagePipeline,
            onNearEnd: content.loadMore,
            onSelect: content.select
        )
    }

    static func makePresentations(
        _ videos: [PopularVideo],
        locale: Locale = .current
    ) -> [NativeVideoCardPresentation] {
        var seenBVIDs: Set<String> = []
        return videos.compactMap { video in
            guard seenBVIDs.insert(video.bvid).inserted else { return nil }
            let presentation = PopularVideoCardPresentation(video: video, locale: locale)
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
                    )
                ],
                coverTrailingText: presentation.durationText,
                footerLeadingText: presentation.footerText,
                accessibilityLabel: ListFormatter.localizedString(
                    byJoining: [
                        presentation.title,
                        presentation.ownerName,
                        AppStrings.localized("播放 \(presentation.viewCountText)", locale: locale),
                        AppStrings.localized("弹幕 \(presentation.danmakuCountText)", locale: locale),
                        AppStrings.localized("时长 \(presentation.durationText)", locale: locale)
                    ]
                )
            )
        }
    }
}
