import BiliApplication
import BiliUI
import Foundation
import SwiftUI

struct GuestVideoDetailView<PlayerContent: View, RelatedContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    let context: GuestVideoContext
    let isPreparingPlayback: Bool
    let danmakuModel: DanmakuControlsViewModel
    let relatedVideoState: RelatedVideoState
    let onSelectRelatedVideo: (String) -> Void
    let onRetryRelatedVideos: () -> Void
    let playerContent: () -> PlayerContent
    let makeRelatedContent:
        (
            String,
            [RelatedVideoCardPresentation],
            @escaping (String) -> Void
        ) -> RelatedContent

    var body: some View {
        mainContent
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
                contentIdentity: context.detail.bvid,
                onSelect: onSelectRelatedVideo,
                onRetry: onRetryRelatedVideos,
                makeLoadedContent: makeRelatedContent
            )
        }
    }

    private var shelfState: RelatedVideoShelfState {
        switch relatedVideoState {
        case .idle, .loading:
            .loading
        case .loaded(let bvid, let videos) where bvid == context.detail.bvid:
            .loaded(
                videos.map { RelatedVideoCardPresentation(video: $0, locale: locale) }
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

            VideoDetailMetadataView(
                content: VideoDetailMetadataContent(
                    viewCount: VideoMetadataFormatting.compactCount(
                        context.detail.statistics.viewCount,
                        locale: locale
                    ),
                    danmakuCount: VideoMetadataFormatting.compactCount(
                        context.detail.statistics.danmakuCount,
                        locale: locale
                    ),
                    publishedAt: VideoMetadataFormatting.fullPublishedDate(
                        context.detail.publishedAt,
                        locale: locale
                    )
                )
            )
        }
    }

    private var player: some View {
        ZStack {
            playerContent()

            if isPreparingPlayback {
                ZStack {
                    Rectangle()
                        .fill(.black)
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.large)
                            .tint(.white)
                        Text(BrowseFeatureStrings.localized("正在准备播放…", locale: locale))
                            .font(.title3)
                            .foregroundStyle(.white)
                    }
                    .environment(\.colorScheme, .dark)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(BrowseFeatureStrings.localized("正在准备播放", locale: locale))
                }
                .transition(
                    .asymmetric(
                        insertion: .identity,
                        removal: .opacity
                    )
                )
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
    }
}

struct VideoDetailMetadataContent {
    let viewCount: String
    let danmakuCount: String
    let publishedAt: String

    static let placeholder = VideoDetailMetadataContent(
        viewCount: "888.8 万",
        danmakuCount: "888.8 万",
        publishedAt: "8888年88月88日 88:88:88"
    )

    var items: [VideoDetailMetadataItem] {
        VideoDetailMetadataSlot.allCases.map { slot in
            VideoDetailMetadataItem(slot: slot, text: text(for: slot))
        }
    }

    private func text(for slot: VideoDetailMetadataSlot) -> String {
        switch slot {
        case .viewCount:
            viewCount
        case .danmakuCount:
            danmakuCount
        case .publishedAt:
            publishedAt
        }
    }
}

struct VideoDetailMetadataItem: Equatable {
    let slot: VideoDetailMetadataSlot
    let text: String
}

enum VideoDetailMetadataSlot: CaseIterable, Hashable {
    case viewCount
    case danmakuCount
    case publishedAt

    var systemImage: String {
        switch self {
        case .viewCount:
            "play"
        case .danmakuCount:
            "text.bubble"
        case .publishedAt:
            "calendar"
        }
    }
}

struct VideoDetailMetadataView: View {
    let content: VideoDetailMetadataContent
    var isPlaceholder = false

    var body: some View {
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
        .redacted(reason: isPlaceholder ? .placeholder : [])
    }

    @ViewBuilder
    private var metadataItems: some View {
        ForEach(content.items, id: \.slot) { item in
            Label(item.text, systemImage: item.slot.systemImage)
        }
    }
}

enum PlaybackPageLayout {
    static let horizontalContentPadding: CGFloat = 40
    static let verticalContentPadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 18
    static let playerAspectRatio: CGFloat = 16.0 / 9.0
}
