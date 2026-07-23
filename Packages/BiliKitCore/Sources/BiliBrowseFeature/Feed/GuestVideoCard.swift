import BiliModels
import Foundation
import SwiftUI

struct GuestVideoCard: View {
    private let title: String
    private let coverURL: URL?
    private let ownerName: String
    private let viewCount: Int64
    private let durationSeconds: Int?
    private let isSelected: Bool

    init(video: PopularVideo, isSelected: Bool) {
        title = video.title
        coverURL = video.coverURL
        ownerName = video.owner.name
        viewCount = video.statistics.viewCount
        durationSeconds = video.durationSeconds
        self.isSelected = isSelected
    }

    init(video: SearchVideo, isSelected: Bool) {
        title = video.title
        coverURL = video.coverURL
        ownerName = video.owner.name
        viewCount = video.statistics.viewCount
        durationSeconds = video.durationSeconds
        self.isSelected = isSelected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: coverURL) { phase in
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
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 9))

                if let durationSeconds {
                    Text(Self.duration(durationSeconds))
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.72), in: Capsule())
                        .padding(7)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        isSelected ? Color.accentColor : .clear,
                        lineWidth: 3
                    )
            }
            .accessibilityHidden(true)

            Text(title)
                .font(.headline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text(ownerName)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Label(
                    viewCount.formatted(.number.notation(.compactName)),
                    systemImage: "play"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
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
