import BiliBrowseFeature
import SwiftUI

struct SearchNativeGridView: View {
    @State private var imageOwner = NativeVideoImagePipelineOwner()
    let presentations: [SearchVideoCardPresentation]
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
            accessibilityLabel: "搜索结果视频",
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
                ),
            ],
            coverTrailingText: presentation.durationText,
            footerLeadingText: presentation.footerText,
            accessibilityLabel: presentation.accessibilityLabel
        )
    }
}
