import BiliModels
import Foundation
import SwiftUI

enum GuestVideoGridLayout {
    static let horizontalSpacing: CGFloat = 20
    static let verticalSpacing: CGFloat = 28
    static let contentPadding: CGFloat = 24

    static func columns(for width: CGFloat) -> [GridItem] {
        let usableWidth = max(0, width - contentPadding * 2)
        let naturalCount = Int(
            (usableWidth + horizontalSpacing) / (240 + horizontalSpacing)
        )
        let columnCount = min(5, max(2, naturalCount))
        return Array(
            repeating: GridItem(
                .flexible(minimum: 200),
                spacing: horizontalSpacing
            ),
            count: columnCount
        )
    }
}

struct GuestVideoCard: View {
    private let title: String
    private let coverURL: URL?
    private let ownerName: String
    private let ownerAvatarURL: URL?
    private let viewCount: Int64
    private let danmakuCount: Int64
    private let durationSeconds: Int?
    private let publishedAt: Date
    private let isSelected: Bool

    init(video: PopularVideo, isSelected: Bool) {
        title = video.title
        coverURL = Self.optimizedBiliImageURL(
            video.coverURL,
            width: 640,
            height: 360
        )
        ownerName = video.owner.name
        ownerAvatarURL = Self.optimizedBiliImageURL(
            video.owner.avatarURL,
            width: 96,
            height: 96
        )
        viewCount = video.statistics.viewCount
        danmakuCount = video.statistics.danmakuCount
        durationSeconds = video.durationSeconds
        publishedAt = video.publishedAt
        self.isSelected = isSelected
    }

    init(video: SearchVideo, isSelected: Bool) {
        title = video.title
        coverURL = Self.optimizedBiliImageURL(
            video.coverURL,
            width: 640,
            height: 360
        )
        ownerName = video.owner.name
        ownerAvatarURL = Self.optimizedBiliImageURL(
            video.owner.avatarURL,
            width: 96,
            height: 96
        )
        viewCount = video.statistics.viewCount
        danmakuCount = video.statistics.danmakuCount
        durationSeconds = video.durationSeconds
        publishedAt = video.publishedAt
        self.isSelected = isSelected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottom) {
                Color.secondary.opacity(0.12)

                AsyncImage(url: coverURL) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                HStack(alignment: .bottom, spacing: 10) {
                    Label(
                        GuestVideoCardFormatting.compactCount(viewCount),
                        systemImage: "play.fill"
                    )
                    Label(
                        GuestVideoCardFormatting.compactCount(danmakuCount),
                        systemImage: "text.bubble.fill"
                    )
                    Spacer(minLength: 8)
                    if let durationSeconds {
                        Text(Self.duration(durationSeconds))
                            .monospacedDigit()
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.top, 22)
                .padding(.bottom, 8)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.78)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isSelected ? Color.accentColor : .clear,
                        lineWidth: 3
                    )
            }
            .accessibilityHidden(true)

            HStack(alignment: .top, spacing: 10) {
                AsyncImage(url: ownerAvatarURL) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .foregroundStyle(.quaternary)
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(Circle())
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(2, reservesSpace: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(
                        "\(ownerName) · "
                            + GuestVideoCardFormatting.publishedDate(publishedAt)
                    )
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static func optimizedBiliImageURL(
        _ url: URL?,
        width: Int,
        height: Int
    ) -> URL? {
        guard let url,
              let host = url.host?.lowercased(),
              host == "hdslb.com" || host.hasSuffix(".hdslb.com"),
              url.query == nil,
              url.fragment == nil,
              !url.path.contains("@")
        else {
            return url
        }
        var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )
        components?.path += "@\(width)w_\(height)h_1c.webp"
        return components?.url ?? url
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

enum GuestVideoCardFormatting {
    static func compactCount(_ count: Int64) -> String {
        let normalizedCount = max(0, count)
        if normalizedCount >= 100_000_000 {
            return compactUnit(
                normalizedCount,
                divisor: 100_000_000,
                suffix: "亿"
            )
        }
        if normalizedCount >= 10_000 {
            return compactUnit(
                normalizedCount,
                divisor: 10_000,
                suffix: "万"
            )
        }
        return String(normalizedCount)
    }

    static func publishedDate(
        _ date: Date,
        relativeTo now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            let elapsedHours = calendar.dateComponents(
                [.hour],
                from: date,
                to: now
            ).hour ?? 0
            return "\(max(1, elapsedHours))小时前"
        }

        if let yesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: now
        ),
           calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "昨天"
        }

        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        if year == calendar.component(.year, from: now) {
            return "\(month)月\(day)日"
        }
        return "\(year)年\(month)月\(day)日"
    }

    private static func compactUnit(
        _ count: Int64,
        divisor: Int64,
        suffix: String
    ) -> String {
        let whole = count / divisor
        let fraction = count % divisor * 10 / divisor
        if fraction == 0 {
            return "\(whole)\(suffix)"
        }
        return "\(whole).\(fraction)\(suffix)"
    }
}
