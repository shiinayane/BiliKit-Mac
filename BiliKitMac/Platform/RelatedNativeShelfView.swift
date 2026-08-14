import BiliBrowseFeature
import SwiftUI

struct RelatedNativeShelfView: View {
    let contentIdentity: String
    let presentations: [RelatedVideoCardPresentation]
    let imagePipeline: NativeVideoImagePipeline
    let onSelect: (String) -> Void

    var body: some View {
        NativeVideoShelfView(
            contentIdentity: contentIdentity,
            items: Self.makePresentations(presentations),
            imagePipeline: imagePipeline,
            onSelect: onSelect
        )
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    static func makePresentations(
        _ presentations: [RelatedVideoCardPresentation]
    ) -> [NativeVideoCardPresentation] {
        presentations.map { presentation in
            NativeVideoCardPresentation(
                id: presentation.bvid,
                title: presentation.title,
                coverURL: presentation.coverURL,
                avatarURL: nil,
                showsAvatar: false,
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
                footerLeadingText: presentation.ownerName,
                accessibilityLabel: presentation.accessibilityLabel,
                accessibilityHelp: "播放并替换当前视频"
            )
        }
    }
}
