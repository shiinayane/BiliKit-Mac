import AppKit
import BiliModels
import BiliVideoCollectionUI
import SwiftUI

/// 整页空间页头部的尺寸；头部高度是网格顶部附加视图的高度，与宽度无关。
enum UploaderSpacePageGeometry {
    static let avatarSize: CGFloat = 72
    static let horizontalPadding: CGFloat = 24
    static let verticalPadding: CGFloat = 18
    static let avatarTextSpacing: CGFloat = 16
    static let lineSpacing: CGFloat = 4
    static let followButtonMinimumWidth: CGFloat = 64
    /// 头像加上下内边距；文字三行（名字、签名、粉丝与投稿数）都单行截断，排得进头像的高度，所以高度只由头像决定。
    static let headerHeight = avatarSize + verticalPadding * 2
}

/// 整页空间页的头部：头像、名字（大会员时用会员色）、签名与粉丝、投稿数，右侧是关注按钮（看自己的空间时没有）。
///
/// 放在网格内容顶部的附加视图里随卡片滚动，所以是嵌套的 `NSHostingView` 的根，拿不到外层 SwiftUI 环境：需要的都由
/// 参数给出。名字、签名与统计都单行截断，高度固定为 `UploaderSpacePageGeometry.headerHeight`。
struct UploaderSpacePageHeader: View {
    let content: VideoUploaderHeaderContent
    let imagePipeline: any VideoDetailImageLoading
    let onToggleFollow: @MainActor () -> Void
    /// 已关注时点按交出按钮背后的视图，由调用方在它下方弹出「已关注」菜单；nil 时点按照旧切换关注。
    ///
    /// 有菜单而按钮背后的视图已经不在（还没挂上或已拆下）时点按什么也不做：退回切换会把“打开菜单”变成直接取消关注。
    let showFollowingMenu: ((NSView) -> Void)?
    /// 按钮背后的 AppKit 视图，菜单弹在它下方；改它不触发重新渲染。
    @State private var menuAnchor = FollowMenuAnchor()

    var body: some View {
        HStack(alignment: .center, spacing: UploaderSpacePageGeometry.avatarTextSpacing) {
            UploaderSpacePageAvatar(
                url: content.avatarURL,
                purpose: content.avatarPurpose,
                imagePipeline: imagePipeline
            )
            .frame(
                width: UploaderSpacePageGeometry.avatarSize,
                height: UploaderSpacePageGeometry.avatarSize
            )
            VStack(alignment: .leading, spacing: UploaderSpacePageGeometry.lineSpacing) {
                Text(content.name)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(
                        Color(nsColor: NativeMemberNameColor.color(isVIP: content.isVIP))
                    )
                if case .text(let signature) = content.signature {
                    Text(signature)
                        .foregroundStyle(.secondary)
                }
                if case .text(let stats) = content.stats {
                    Text(stats)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if let follow = content.follow {
                Button {
                    if follow.isFollowing, let showFollowingMenu {
                        if let view = menuAnchor.view { showFollowingMenu(view) }
                    } else {
                        onToggleFollow()
                    }
                } label: {
                    Label(
                        UploaderFollowButtonLabel.title(isFollowing: follow.isFollowing),
                        systemImage: UploaderFollowButtonLabel.systemImage(
                            isFollowing: follow.isFollowing
                        )
                    )
                    .frame(minWidth: UploaderSpacePageGeometry.followButtonMinimumWidth)
                }
                .modifier(UploaderFollowButtonStyle(isProminent: !follow.isFollowing))
                .controlSize(.large)
                .disabled(!follow.isEnabled)
                // 与播放页侧栏的按钮一致：标签固定为「关注」，值说明是否已关注。
                .accessibilityLabel(UploaderFollowButtonLabel.accessibilityLabel)
                .accessibilityValue(
                    UploaderFollowButtonLabel.accessibilityValue(isFollowing: follow.isFollowing)
                )
                .background(FollowMenuAnchorView(anchor: menuAnchor))
            }
        }
        .padding(.horizontal, UploaderSpacePageGeometry.horizontalPadding)
        .frame(height: UploaderSpacePageGeometry.headerHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 头部的圆形头像：先取已解码的缓存，没有再经窗口图片管线加载；地址变了重新取。
private struct UploaderSpacePageAvatar: View {
    let url: URL?
    let purpose: VideoDetailImagePurpose
    let imagePipeline: any VideoDetailImageLoading
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Circle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            }
        }
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let cached = imagePipeline.cachedImage(for: url, purpose: purpose) {
                image = cached
                return
            }
            image = await imagePipeline.image(for: url, purpose: purpose)?.image
        }
    }
}

/// 关注按钮的样式：macOS 26 起是胶囊形的液态玻璃，「关注」用强调色的玻璃；更早的系统用带边框按钮，「关注」染强调色。
///
/// 胶囊形写明而不靠自动形状：自动形状按尺寸档决定，播放页侧栏那一个是 small 档、会成圆角矩形，两处要一致。
private struct UploaderFollowButtonStyle: ViewModifier {
    let isProminent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if isProminent {
                content.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
            } else {
                content.buttonStyle(.glass).buttonBorderShape(.capsule)
            }
        } else {
            content
                .buttonStyle(.bordered)
                .tint(isProminent ? .accentColor : nil)
        }
    }
}

/// 弱引用关注按钮背后的那块 AppKit 视图；头部是嵌套 `NSHostingView` 的根，菜单要按它定位。
private final class FollowMenuAnchor {
    weak var view: NSView?
}

private struct FollowMenuAnchorView: NSViewRepresentable {
    let anchor: FollowMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}
