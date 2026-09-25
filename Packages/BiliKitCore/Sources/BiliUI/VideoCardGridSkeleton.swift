import SwiftUI

/// 首载骨架：列数、卡片尺寸、间距与内容边距都取自生产网格的 `VideoCardGridGeometry`。
package struct VideoCardGridSkeleton: View {
    private static let placeholderCount = 12
    private let loadingLabel: String

    package init(loadingLabel: String) {
        self.loadingLabel = loadingLabel
    }

    package var body: some View {
        GeometryReader { geometry in
            let itemSize = VideoCardGridGeometry.itemSize(for: geometry.size.width)
            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(
                            .fixed(itemSize.width),
                            spacing: VideoCardGridGeometry.horizontalSpacing
                        ),
                        count: VideoCardGridGeometry.columnCount(for: geometry.size.width)
                    ),
                    alignment: .leading,
                    spacing: VideoCardGridGeometry.verticalSpacing
                ) {
                    ForEach(0..<Self.placeholderCount, id: \.self) { _ in
                        VideoCardSkeleton(size: itemSize)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, VideoCardGridGeometry.topContentPadding)
                .padding([.horizontal, .bottom], VideoCardGridGeometry.contentPadding)
            }
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loadingLabel)
    }
}

/// 与原生卡片同一布局：封面、头像、两行标题与 footer 的位置都来自 `VideoCardGeometry`。
private struct VideoCardSkeleton: View {
    private static let barCornerRadius: CGFloat = 4
    private static let titleBarHeight: CGFloat = 18
    private static let titleBarSpacing: CGFloat = 8
    private static let secondTitleBarMaximumWidth: CGFloat = 180
    private static let footerBarHeight: CGFloat = 14
    private static let footerBarMaximumWidth: CGFloat = 130

    let size: CGSize

    var body: some View {
        let coverHeight = VideoCardGeometry.coverHeight(forWidth: size.width)
        let textInset = VideoCardGeometry.textLeadingInset(showsAvatar: true)
        let textWidth = max(0, size.width - textInset)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: VideoCardGeometry.coverCornerRadius)
                .fill(.quaternary)
                .frame(width: size.width, height: coverHeight)
            Circle()
                .fill(.quaternary)
                .frame(
                    width: VideoCardGeometry.avatarSize,
                    height: VideoCardGeometry.avatarSize
                )
                .offset(y: coverHeight + VideoCardGeometry.textTopSpacing)
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
