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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let coverURL: URL?
    private let avatarURL: URL?
    private let showsAvatar: Bool
    private let title: String
    private let coverMetrics: [VideoCardMetric]
    private let coverTrailingText: String?
    private let footerLeadingText: String
    private let footerTrailingText: String?

    package init(
        coverURL: URL?,
        avatarURL: URL?,
        showsAvatar: Bool,
        title: String,
        coverMetrics: [VideoCardMetric] = [],
        coverTrailingText: String? = nil,
        footerLeadingText: String,
        footerTrailingText: String? = nil
    ) {
        self.coverURL = coverURL
        self.avatarURL = avatarURL
        self.showsAvatar = showsAvatar
        self.title = title
        self.coverMetrics = coverMetrics
        self.coverTrailingText = coverTrailingText
        self.footerLeadingText = footerLeadingText
        self.footerTrailingText = footerTrailingText
    }

    package var body: some View {
        VideoCardLayout(showsLeading: showsAvatar) {
            cover
        } leading: {
            avatar
        } title: {
            titleContent
        } footer: {
            footer
        }
        .accessibilityElement(children: .combine)
    }

    private var cover: some View {
        Color.secondary.opacity(0.12)
            .overlay {
                AsyncImage(
                    url: coverURL,
                    transaction: imageLoadingTransaction
                ) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    default:
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                            .transition(.opacity)
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
    }

    private var avatar: some View {
        AsyncImage(
            url: avatarURL,
            transaction: imageLoadingTransaction
        ) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            default:
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.quaternary)
                    .transition(.opacity)
            }
        }
        .accessibilityHidden(true)
    }

    private var imageLoadingTransaction: Transaction {
        Transaction(
            animation: LoadingStateTransition.animation(
                reduceMotion: reduceMotion
            )
        )
    }

    private var titleContent: some View {
        Text(title)
            .font(.title3.weight(.medium))
            .lineLimit(2, reservesSpace: true)
    }

    private var footer: some View {
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
