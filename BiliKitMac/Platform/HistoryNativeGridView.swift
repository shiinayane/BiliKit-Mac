import BiliLibraryFeature
import SwiftUI

struct HistoryNativeGridView: View {
    @State private var imageOwner = NativeVideoImagePipelineOwner()
    let presentations: [WatchHistoryCardPresentation]
    @Binding var scrollOffsetY: CGFloat
    let canLoadMore: Bool
    let tailIdentity: String?
    let isLoading: Bool
    @Binding var scrollReset: NativeVideoGridScrollResetState
    let onNearEnd: () -> Void
    let onSelect: (String) -> Void

    var body: some View {
        NativeVideoGridView(
            items: presentations.map(Self.makePresentation),
            scrollOffsetY: $scrollOffsetY,
            accessibilityLabel: "观看历史视频",
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
