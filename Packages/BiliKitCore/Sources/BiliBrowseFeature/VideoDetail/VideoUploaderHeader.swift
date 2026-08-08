import BiliModels
import BiliUI
import SwiftUI

/// 播放 Sidebar 顶部的只读 UP 主摘要。
///
/// 只投影 `VideoOwner` 的展示字段，不拥有 UP 主资料请求、关注或充电行为。未来接入独立
/// 资料来源时只需更新 owner 数据，Sidebar 的布局与播放生命周期保持不变。
struct VideoUploaderHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .callout)
    private var signatureSkeletonHeight =
        VideoUploaderHeaderMetrics.signatureSkeletonHeight

    private let content: VideoUploaderHeaderContent

    init(owner: VideoOwner) {
        self.init(
            owner: owner,
            signatureState: .loaded(owner.signature)
        )
    }

    init(
        owner: VideoOwner,
        signatureState: VideoUploaderSignatureState
    ) {
        content = VideoUploaderHeaderContent(
            owner: owner,
            signatureState: signatureState
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            avatar

            VStack(
                alignment: .leading,
                spacing: VideoUploaderHeaderMetrics.textSpacing
            ) {
                Text(content.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                signature
                    .animation(
                        LoadingStateTransition.animation(
                            reduceMotion: reduceMotion
                        ),
                        value: content.signature
                    )
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel)
        .accessibilityIdentifier("sidebar.playback-uploader")
    }

    @ViewBuilder
    private var signature: some View {
        switch content.signature {
        case .loading:
            RoundedRectangle(cornerRadius: 3)
                .fill(.quinary)
                .frame(
                    width: VideoUploaderHeaderMetrics.signatureSkeletonWidth,
                    height: signatureSkeletonHeight
                )
                .transition(.opacity)
                .accessibilityHidden(true)
        case .text(let signature):
            Text(signature)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .transition(.opacity)
        case .hidden:
            EmptyView()
        }
    }

    private var avatar: some View {
        AsyncImage(
            url: content.avatarURL,
            transaction: Transaction(
                animation: LoadingStateTransition.animation(
                    reduceMotion: reduceMotion
                )
            )
        ) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            default:
                fallbackAvatar
                    .transition(.opacity)
            }
        }
        .frame(
            width: VideoUploaderHeaderMetrics.avatarSize,
            height: VideoUploaderHeaderMetrics.avatarSize
        )
        .background(Color.secondary.opacity(0.1))
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private var fallbackAvatar: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
    }
}

enum VideoUploaderHeaderMetrics {
    static let avatarSize: CGFloat = 48
    static let textSpacing: CGFloat = 4
    static let nameSkeletonWidth: CGFloat = 128
    static let nameSkeletonHeight: CGFloat = 20
    static let signatureSkeletonWidth: CGFloat = 196
    static let signatureSkeletonHeight: CGFloat = 14
}

enum VideoUploaderSignatureState: Equatable, Sendable {
    case loading
    case loaded(String?)
}

enum VideoUploaderSignatureContent: Equatable, Sendable {
    case loading
    case hidden
    case text(String)
}

struct VideoUploaderHeaderContent: Equatable, Sendable {
    let name: String
    let avatarURL: URL?
    let signature: VideoUploaderSignatureContent

    init(
        owner: VideoOwner,
        signatureState: VideoUploaderSignatureState? = nil
    ) {
        let normalizedName = Self.normalized(owner.name)
        name = normalizedName ?? "未知 UP 主"
        avatarURL = owner.avatarURL
        switch signatureState ?? .loaded(owner.signature) {
        case .loading:
            signature = .loading
        case .loaded(let value):
            signature =
                Self.normalized(value).map {
                    .text($0)
                } ?? .hidden
        }
    }

    var accessibilityLabel: String {
        switch signature {
        case .loading:
            return "UP 主，\(name)，签名正在加载"
        case .text(let signature):
            return "UP 主，\(name)，签名，\(signature)"
        case .hidden:
            return "UP 主，\(name)"
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized =
            value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}
