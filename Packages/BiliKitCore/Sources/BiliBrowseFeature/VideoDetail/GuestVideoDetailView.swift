import BiliApplication
import BiliUI
import Foundation
import SwiftUI

struct GuestVideoDetailView<PlayerContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let context: GuestVideoContext
    let isPreparingPlayback: Bool
    let danmakuModel: DanmakuControlsViewModel
    let relatedVideoState: RelatedVideoState
    let onSelectRelatedVideo: (String) -> Void
    let onRetryRelatedVideos: () -> Void
    let playerContent: () -> PlayerContent

    var body: some View {
        mainContent
            .accessibilityIdentifier("playback.destination")
            .navigationTitle(context.detail.title)
    }

    private var mainContent: some View {
        PlaybackDetailLayout {
            metadata
        } player: {
            player
        } controls: {
            DanmakuControlsView(model: danmakuModel)
        } related: {
            RelatedVideoShelf(
                state: shelfState,
                onSelect: onSelectRelatedVideo,
                onRetry: onRetryRelatedVideos
            )
        }
    }

    private var shelfState: RelatedVideoShelfState {
        switch relatedVideoState {
        case .idle, .loading:
            .loading
        case .loaded(let bvid, let videos) where bvid == context.detail.bvid:
            .loaded(
                videos.map {
                    RelatedVideoShelfItem(
                        bvid: $0.bvid,
                        title: $0.title,
                        coverURL: $0.coverURL,
                        ownerName: $0.ownerName,
                        viewCount: $0.viewCount,
                        danmakuCount: $0.danmakuCount,
                        durationSeconds: $0.durationSeconds
                    )
                }
            )
        case .empty(let bvid) where bvid == context.detail.bvid:
            .empty
        case .failed(let bvid, _) where bvid == context.detail.bvid:
            .failure
        case .loaded, .empty, .failed:
            .loading
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
                ZStack {
                    Rectangle()
                        .fill(.black.opacity(0.45))
                    ProgressView("正在准备播放…")
                        .controlSize(.large)
                        .font(.title3)
                        .foregroundStyle(.white)
                }
                .transition(.opacity)
            }
        }
        .animation(
            LoadingStateTransition.animation(reduceMotion: reduceMotion),
            value: isPreparingPlayback
        )
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
    static let sectionSpacing: CGFloat = 18
    static let playerAspectRatio: CGFloat = 16.0 / 9.0
}
