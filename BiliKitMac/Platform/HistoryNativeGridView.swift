import BiliLibraryFeature
import SwiftUI

struct HistoryNativeGridView: View {
    let content: LoadedHistoryContent
    @Binding var scrollOffsetY: CGFloat
    @Binding var scrollReset: NativeVideoGridScrollResetState
    let imagePipeline: NativeVideoImagePipeline

    var body: some View {
        NativeVideoGridView(
            items: content.items.map(Self.makePresentation),
            scrollOffsetY: $scrollOffsetY,
            accessibilityLabel: AppStrings.localized("观看历史视频"),
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
        _ presentation: WatchHistoryCardPresentation
    ) -> NativeVideoCardPresentation {
        NativeVideoCardPresentation(
            id: presentation.bvid,
            title: presentation.title,
            coverURL: presentation.coverURL,
            avatarURL: presentation.avatarURL,
            showsAvatar: presentation.showsAvatar,
            coverTrailingText: presentation.progressText,
            footerLeadingText: presentation.footerLeadingText,
            footerTrailingText: presentation.footerTrailingText,
            accessibilityLabel: presentation.accessibilityLabel
        )
    }
}
