import SwiftUI

/// 单张视频卡片的加载占位，与原生卡片同一布局：封面、头像、两行标题与 footer 的位置都来自 `VideoCardGeometry`。
///
/// 网格骨架（`VideoCardGridSkeleton`）使用；调用方给出卡片尺寸与是否带头像，须与对应真实卡片一致（不带头像时
/// 文字从左缘开始）。不读屏，读屏文案由外层骨架给出。
package struct VideoCardSkeleton: View {
    private static let barCornerRadius: CGFloat = 4
    private static let titleBarHeight: CGFloat = 18
    private static let titleBarSpacing: CGFloat = 8
    private static let secondTitleBarMaximumWidth: CGFloat = 180
    private static let footerBarHeight: CGFloat = 14
    private static let footerBarMaximumWidth: CGFloat = 130

    private let size: CGSize
    private let showsAvatar: Bool

    package init(size: CGSize, showsAvatar: Bool) {
        self.size = size
        self.showsAvatar = showsAvatar
    }

    package var body: some View {
        let coverHeight = VideoCardGeometry.coverHeight(forWidth: size.width)
        let textInset = VideoCardGeometry.textLeadingInset(showsAvatar: showsAvatar)
        let textWidth = max(0, size.width - textInset)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: VideoCardGeometry.coverCornerRadius)
                .fill(.quaternary)
                .frame(width: size.width, height: coverHeight)
            if showsAvatar {
                Circle()
                    .fill(.quaternary)
                    .frame(
                        width: VideoCardGeometry.avatarSize,
                        height: VideoCardGeometry.avatarSize
                    )
                    .offset(y: coverHeight + VideoCardGeometry.textTopSpacing)
            }
            VStack(alignment: .leading, spacing: Self.titleBarSpacing) {
                bar(width: textWidth, height: Self.titleBarHeight)
                bar(
                    width: min(textWidth, Self.secondTitleBarMaximumWidth),
                    height: Self.titleBarHeight
                )
            }
            .frame(height: VideoCardGeometry.titleHeight, alignment: .top)
            .offset(x: textInset, y: coverHeight + VideoCardGeometry.textTopSpacing)
            bar(
                width: min(textWidth, Self.footerBarMaximumWidth),
                height: Self.footerBarHeight,
                style: .quinary
            )
            .frame(height: VideoCardGeometry.footerHeight)
            .offset(x: textInset, y: coverHeight + VideoCardGeometry.footerTopOffset)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func bar(
        width: CGFloat,
        height: CGFloat,
        style: HierarchicalShapeStyle = .quaternary
    ) -> some View {
        RoundedRectangle(cornerRadius: Self.barCornerRadius)
            .fill(style)
            .frame(width: width, height: height)
    }
}
