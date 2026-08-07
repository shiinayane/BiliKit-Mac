import BiliApplication
import BiliUI
import Foundation
import SwiftUI

struct GuestVideoDetailView<PlayerContent: View>: View {
    let context: GuestVideoContext
    let isPreparingPlayback: Bool
    let subtitleModel: SubtitleViewModel
    let danmakuModel: DanmakuControlsViewModel
    let subtitlePresentationMode: SubtitlePresentationMode
    let playerContent: () -> PlayerContent

    var body: some View {
        mainContent
            .accessibilityIdentifier("playback.destination")
            .navigationTitle(context.detail.title)
    }

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                metadata
                player

                if subtitlePresentationMode == .legacyOverlay {
                    Divider()
                    SubtitleControlsView(model: subtitleModel)
                }

                Divider()
                DanmakuControlsView(model: danmakuModel)
            }
            .padding(
                .horizontal,
                PlaybackPageLayout.horizontalContentPadding
            )
            .padding(
                .vertical,
                PlaybackPageLayout.verticalContentPadding
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(context.detail.title)
                .font(.title.weight(.semibold))
                .textSelection(.enabled)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    metadataItems
                }

                VStack(alignment: .leading, spacing: 8) {
                    metadataItems
                }
            }
            .font(.body)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var metadataItems: some View {
        Label(
            context.detail.owner.name,
            systemImage: "person.crop.circle"
        )
        Label(
            VideoMetadataFormatting.compactCount(
                context.detail.statistics.viewCount
            ),
            systemImage: "play"
        )
        Label(
            VideoMetadataFormatting.compactCount(
                context.detail.statistics.danmakuCount
            ),
            systemImage: "text.bubble"
        )
        Label(
            VideoMetadataFormatting.fullPublishedDate(
                context.detail.publishedAt
            ),
            systemImage: "calendar"
        )
    }

    private var player: some View {
        ZStack {
            playerContent()
                .accessibilityIdentifier("player.host")

            if isPreparingPlayback {
                Rectangle()
                    .fill(.black.opacity(0.45))
                ProgressView("正在准备播放…")
                    .controlSize(.large)
                    .font(.title3)
                    .foregroundStyle(.white)
            }
        }
        .aspectRatio(
            PlaybackPageLayout.playerAspectRatio,
            contentMode: .fit
        )
        .frame(maxWidth: .infinity)
        .background(.black)
        .accessibilityIdentifier("playback.player.container")
    }
}

enum PlaybackPageLayout {
    static let horizontalContentPadding: CGFloat = 40
    static let verticalContentPadding: CGFloat = 24
    static let playerAspectRatio: CGFloat = 16.0 / 9.0
}
