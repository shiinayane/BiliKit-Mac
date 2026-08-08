import BiliModels
import BiliUI
import SwiftUI

/// 播放 Sidebar 顶部的只读 UP 主摘要。
///
/// 只投影 `VideoOwner` 的展示字段，不拥有 UP 主资料请求、关注或充电行为。未来接入独立
/// 资料来源时只需更新 owner 数据，Sidebar 的布局与播放生命周期保持不变。
struct VideoUploaderHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSignatureExpanded = false
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
                    .textSelection(.enabled)
                    .accessibilityLabel("UP 主，\(content.name)")

                signature
                    .animation(
                        LoadingStateTransition.animation(
                            reduceMotion: reduceMotion
                        ),
                        value: content.signature
                    )
                    .onChange(of: content.signature) {
                        isSignatureExpanded = false
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
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
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("签名正在加载")
        case .text(let signature):
            ViewThatFits(in: .horizontal) {
                signatureText(signature, lineLimit: 1)
                    .fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled)
                    .accessibilityIdentifier(
                        "sidebar.playback-uploader.signature"
                    )

                Button {
                    withAnimation(
                        LoadingStateTransition.animation(
                            reduceMotion: reduceMotion
                        )
                    ) {
                        isSignatureExpanded.toggle()
                    }
                } label: {
                    signatureText(
                        signature,
                        lineLimit: isSignatureExpanded ? nil : 1
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("UP 主签名")
                .accessibilityValue(
                    isSignatureExpanded ? "已展开，\(signature)" : "已收起，\(signature)"
                )
                .accessibilityHint(
                    isSignatureExpanded ? "点击收起" : "点击展开完整签名"
                )
                .accessibilityIdentifier(
                    "sidebar.playback-uploader.signature"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        case .hidden:
            EmptyView()
        }
    }

    private func signatureText(
        _ signature: String,
        lineLimit: Int?
    ) -> some View {
        Text(signature)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
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

public enum VideoUploaderSignatureState: Equatable, Sendable {
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
