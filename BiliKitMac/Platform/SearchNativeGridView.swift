import BiliBrowseFeature
import SwiftUI

struct SearchNativeGridView: View {
    let content: LoadedFeedContent<SearchVideoCardPresentation>
    @Binding var scrollOffsetY: CGFloat
    @Binding var scrollReset: NativeVideoGridScrollResetState
    let imagePipeline: NativeVideoImagePipeline

    var body: some View {
        NativeVideoGridView(
            items: content.items.map(Self.makePresentation),
            scrollOffsetY: $scrollOffsetY,
            accessibilityLabel: AppStrings.localized("搜索结果视频"),
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

    static func makePresentation(
        _ presentation: SearchVideoCardPresentation
    ) -> NativeVideoCardPresentation {
        NativeVideoCardPresentation(
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
            accessibilityLabel: presentation.accessibilityLabel
        )
    }
}
