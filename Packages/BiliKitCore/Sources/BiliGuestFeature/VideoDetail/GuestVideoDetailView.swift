import BiliApplication
import Foundation
import SwiftUI

struct GuestVideoDetailView<PlayerContent: View>: View {
    let context: GuestVideoContext
    let isPreparingPlayback: Bool
    let playerContent: () -> PlayerContent

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                playerContent()
                    .accessibilityIdentifier("player.host")

                if isPreparingPlayback {
                    Rectangle()
                        .fill(.black.opacity(0.45))
                    ProgressView("正在准备播放…")
                        .controlSize(.large)
                        .foregroundStyle(.white)
                }
            }
            .frame(minHeight: 280, idealHeight: 420, maxHeight: 500)
            .background(.black)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(context.detail.title)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)

                        HStack(spacing: 16) {
                            Label(context.detail.owner.name, systemImage: "person.crop.circle")
                            Label(
                                context.detail.statistics.viewCount.formatted(
                                    .number.notation(.compactName)
                                ),
                                systemImage: "play"
                            )
                            Label(
                                context.detail.statistics.danmakuCount.formatted(
                                    .number.notation(.compactName)
                                ),
                                systemImage: "text.bubble"
                            )
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }

                    if !context.detail.summary.isEmpty {
                        Text(context.detail.summary)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("分 P")
                            .font(.headline)

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
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(context.detail.title)
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
