import BiliApplication
import Foundation
import SwiftUI

struct GuestVideoDetailView<PlayerContent: View>: View {
    let context: GuestVideoContext
    let isPreparingPlayback: Bool
    let subtitleModel: SubtitleViewModel
    let danmakuModel: DanmakuControlsViewModel
    let playerContent: () -> PlayerContent

    var body: some View {
        GeometryReader { geometry in
            if let mode = PlaybackPageLayout.mode(
                availableWidth: geometry.size.width,
                pageCount: context.pages.count
            ) {
                HStack(spacing: 0) {
                    mainContent(mode: mode)

                    if mode == .wideParts {
                        Divider()
                        partsRail
                    }
                }
                .accessibilityIdentifier(mode.accessibilityIdentifier)
            }
        }
        .navigationTitle(context.detail.title)
    }

    private func mainContent(mode: PlaybackPageLayoutMode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                metadata
                player

                Divider()
                SubtitleControlsView(model: subtitleModel)

                Divider()
                DanmakuControlsView(model: danmakuModel)

                if mode == .compactParts {
                    Divider()
                    DisclosureGroup("分 P") {
                        partsList
                            .padding(.top, 10)
                    }
                    .font(.title3)
                    .accessibilityIdentifier("playback.parts.compact")
                }

                if !context.detail.summary.isEmpty {
                    Divider()
                    Text(context.detail.summary)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
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

            HStack(spacing: 16) {
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
            .font(.body)
            .foregroundStyle(.secondary)
        }
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

    private var partsRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("分 P")
                    .font(.title3.weight(.semibold))
                partsList
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
        .frame(width: PlaybackPageLayout.partsRailWidth)
        .accessibilityIdentifier("playback.parts.rail")
    }

    private var partsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(context.pages) { page in
                HStack(spacing: 10) {
                    Image(
                        systemName: page.id == context.selectedPage.id
                            ? "play.circle.fill"
                            : "circle"
                    )
                    .foregroundStyle(
                        page.id == context.selectedPage.id
                            ? Color.accentColor
                            : Color.secondary
                    )
                    Text("P\(page.index)  \(page.title)")
                        .lineLimit(2)
                    Spacer(minLength: 12)
                    Text(Self.duration(page.durationSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .font(.title3)
    }

    private static func duration(_ seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = seconds % 3_600 / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                remainingSeconds
            )
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

enum PlaybackPageLayoutMode: Equatable {
    case singlePart
    case compactParts
    case wideParts

    var accessibilityIdentifier: String {
        switch self {
        case .singlePart:
            "playback.layout.single"
        case .compactParts:
            "playback.layout.compact"
        case .wideParts:
            "playback.layout.wide"
        }
    }
}

enum PlaybackPageLayout {
    static let horizontalContentPadding: CGFloat = 40
    static let verticalContentPadding: CGFloat = 24
    static let partsRailWidth: CGFloat = 400
    static let playerAspectRatio: CGFloat = 16.0 / 9.0
    static let widePartsThreshold: CGFloat = 1_000

    static func mode(
        availableWidth: CGFloat,
        pageCount: Int
    ) -> PlaybackPageLayoutMode? {
        guard pageCount > 0 else { return nil }
        guard pageCount > 1 else { return .singlePart }
        return availableWidth >= widePartsThreshold
            ? .wideParts
            : .compactParts
    }

    static func playerSize(availableWidth: CGFloat) -> CGSize {
        let width = max(
            0,
            availableWidth - horizontalContentPadding * 2
        )
        return CGSize(width: width, height: width / playerAspectRatio)
    }
}
