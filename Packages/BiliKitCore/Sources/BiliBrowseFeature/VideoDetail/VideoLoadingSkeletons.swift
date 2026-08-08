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
            RelatedVideoShelf(
                state: .loading,
                onSelect: { _ in },
                onRetry: {}
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

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    metadataItems
                }

                VStack(alignment: .leading, spacing: 8) {
                    metadataItems
                }
            }
        }
    }

    @ViewBuilder
    private var metadataItems: some View {
        metadataItem(width: 120)
        metadataItem(width: 84)
        metadataItem(width: 84)
        metadataItem(width: 104)
    }

    private func metadataItem(width: CGFloat) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(.quinary)
                .frame(width: 14, height: 14)
            RoundedRectangle(cornerRadius: 3)
                .fill(.quinary)
                .frame(width: width, height: 14)
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
            VStack(alignment: .leading, spacing: 16) {
                uploader

                Divider()

                sectionTitle(width: 64)
                textLine()
                textLine(width: 0.9)
                textLine(width: 0.68)

                Divider()

                sectionTitle(width: 92)
                ForEach(0..<3, id: \.self) { _ in
                    partRow
                }

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

    private var partRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.quinary)
                .frame(width: 16, height: 16)
            RoundedRectangle(cornerRadius: 3)
                .fill(.quinary)
                .frame(width: 32, height: 14)
            RoundedRectangle(cornerRadius: 3)
                .fill(.quaternary)
                .frame(maxWidth: .infinity)
                .frame(height: 14)
        }
        .frame(height: 32)
    }
}
