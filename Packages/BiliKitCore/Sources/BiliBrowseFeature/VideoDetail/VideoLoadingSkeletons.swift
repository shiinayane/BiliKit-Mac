import SwiftUI

struct VideoDetailSkeleton: View {
    let loadingLabel: String

    var body: some View {
        PlaybackDetailLayout {
            metadata
        } player: {
            player
        } controls: {
            controls
        } related: {
            RelatedVideoShelf<EmptyView>(
                state: .loading,
                contentIdentity: "loading",
                onSelect: { _ in },
                onRetry: {},
                makeLoadedContent: { _, _, _ in EmptyView() }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loadingLabel)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 5)
                .fill(.quaternary)
                .frame(maxWidth: 520)
                .frame(height: 30)

            VideoDetailMetadataView(
                content: .placeholder,
                isPlaceholder: true
            )
        }
    }

    private var player: some View {
        Rectangle()
            .fill(.black)
            .overlay {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
            .aspectRatio(
                PlaybackPageLayout.playerAspectRatio,
                contentMode: .fit
            )
            .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 7)
                .fill(.quaternary)
                .frame(width: 92, height: 28)
            RoundedRectangle(cornerRadius: 7)
                .fill(.quaternary)
                .frame(width: 108, height: 28)
            Spacer()
        }
    }
}
