import BiliAPI
import Foundation
import SwiftUI

struct PopularVideoRow: View {
    let video: PopularVideo

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: video.coverURL) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    ZStack {
                        Color.secondary.opacity(0.12)
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: 128, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(video.title)
                    .font(.headline)
                    .lineLimit(2)

                Text(video.owner.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 10) {
                    Label(
                        video.statistics.viewCount.formatted(.number.notation(.compactName)),
                        systemImage: "play"
                    )
                    Label(
                        Self.duration(video.durationSeconds),
                        systemImage: "clock"
                    )
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
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
