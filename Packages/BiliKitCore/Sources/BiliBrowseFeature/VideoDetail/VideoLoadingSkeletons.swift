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
        .background(.background)
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

struct PlaybackContextSidebarSkeleton: View {
    let loadingLabel: String

    @ScaledMetric(relativeTo: .title3)
    private var uploaderNameSkeletonHeight =
        VideoUploaderHeaderMetrics.nameSkeletonHeight
    @ScaledMetric(relativeTo: .callout)
    private var uploaderSignatureSkeletonHeight =
        VideoUploaderHeaderMetrics.signatureSkeletonHeight

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                uploader

                Divider()

                sectionTitle(width: 64)
                textLine()
                textLine(width: 0.9)
                textLine(width: 0.68)

                Divider()

                sectionTitle(width: 132)
                selectionField
                selectionField

                Divider()

                sectionTitle(width: 116)
                textLine(width: 0.82)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loadingLabel)
    }

    private var uploader: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.quaternary)
                .frame(
                    width: VideoUploaderHeaderMetrics.avatarSize,
                    height: VideoUploaderHeaderMetrics.avatarSize
                )

            VStack(
                alignment: .leading,
                spacing: VideoUploaderHeaderMetrics.textSpacing
            ) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(
                        width: VideoUploaderHeaderMetrics.nameSkeletonWidth,
                        height: uploaderNameSkeletonHeight
                    )

                RoundedRectangle(cornerRadius: 3)
                    .fill(.quinary)
                    .frame(
                        maxWidth:
                            VideoUploaderHeaderMetrics.signatureSkeletonWidth
                    )
                    .frame(height: uploaderSignatureSkeletonHeight)
            }
        }
    }

    private func sectionTitle(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.quaternary)
            .frame(width: width, height: 18)
    }

    private func textLine(width: CGFloat = 1) -> some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 3)
                .fill(.quinary)
                .frame(width: geometry.size.width * width, height: 13)
        }
        .frame(height: 13)
    }

    private var selectionField: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(.quinary)
                .frame(width: 42, height: 14)
            RoundedRectangle(cornerRadius: 3)
                .fill(.quaternary)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
        }
    }
}
