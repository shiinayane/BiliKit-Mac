import BiliModels
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
    let onToggleFollow: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: UploaderSpacePageGeometry.avatarTextSpacing) {
            UploaderSpacePageAvatar(url: content.avatarURL, imagePipeline: imagePipeline)
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
                Button(action: onToggleFollow) {
                    Text(
                        follow.isFollowing
                            ? VideoDetailFeatureStrings.localized("已关注")
                            : VideoDetailFeatureStrings.localized("关注")
                    )
                    .frame(minWidth: UploaderSpacePageGeometry.followButtonMinimumWidth)
                }
                .buttonStyle(.bordered)
                .tint(follow.isFollowing ? nil : .accentColor)
                .controlSize(.large)
                .disabled(!follow.isEnabled)
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
            if let cached = imagePipeline.cachedImage(for: url, purpose: .avatar) {
                image = cached
                return
            }
            image = await imagePipeline.image(for: url, purpose: .avatar)?.image
        }
    }
}
