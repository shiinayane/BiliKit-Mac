import SwiftUI

package struct VideoCardMetric: Sendable, Equatable {
    package let text: String
    package let systemImage: String

    package init(_ text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }
}

package struct VideoCard: View {
    private let coverURL: URL?
    private let avatarURL: URL?
    private let showsAvatar: Bool
    private let title: String
    private let coverMetrics: [VideoCardMetric]
    private let coverTrailingText: String?
    private let footerLeadingText: String
    private let footerTrailingText: String?
    private let isSelected: Bool

    package init(
        coverURL: URL?,
        avatarURL: URL?,
        showsAvatar: Bool,
        title: String,
        coverMetrics: [VideoCardMetric] = [],
        coverTrailingText: String? = nil,
        footerLeadingText: String,
        footerTrailingText: String? = nil,
        isSelected: Bool
    ) {
        self.coverURL = coverURL
        self.avatarURL = avatarURL
        self.showsAvatar = showsAvatar
        self.title = title
        self.coverMetrics = coverMetrics
        self.coverTrailingText = coverTrailingText
        self.footerLeadingText = footerLeadingText
        self.footerTrailingText = footerTrailingText
        self.isSelected = isSelected
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cover
            details
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var cover: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
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
                .accessibilityHidden(true)
            }
            .overlay(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(coverMetrics.indices, id: \.self) { index in
                        let metric = coverMetrics[index]
                        Label(metric.text, systemImage: metric.systemImage)
                    }
                    Spacer(minLength: 8)
                    if let coverTrailingText {
                        Text(coverTrailingText)
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
                    .accessibilityHidden(true)
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var details: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsAvatar {
                AsyncImage(url: avatarURL) { phase in
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
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.medium))
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Text(footerLeadingText)
                        .lineLimit(1)
                    if let footerTrailingText {
                        Spacer(minLength: 8)
                        Text(footerTrailingText)
                            .lineLimit(1)
                            .monospacedDigit()
                    }
                }
                .font(.body)
                .foregroundStyle(.secondary)
            }
        }
    }
}
