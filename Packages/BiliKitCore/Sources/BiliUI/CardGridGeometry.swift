import Foundation

/// 卡片网格几何的唯一实现：列数、卡片尺寸、内容高度与骨架占位数都按这里的参数算。
///
/// 每种卡片一个实例：视频卡片是 `video`（BiliVideoCollectionUI 的原生网格与 BiliUI 的加载骨架共用），人物卡片的实例
/// 在 BiliVideoCollectionUI。组合布局的一节与近尾判断依赖 AppKit，由 BiliVideoCollectionUI 在扩展里按同一组参数实现；
/// 公式只写在这里，各实例只给取值。
package struct CardGridGeometry: Sendable {
    /// 首行之上的内容边距；各种卡片都贴着顶边（顶部附加视图与工具栏留白另算），所以不按实例变化。
    package static let topContentPadding: CGFloat = 0

    /// 左、右与底边的内容边距。
    package let contentPadding: CGFloat
    package let horizontalSpacing: CGFloat
    /// 行与行之间的间距。
    package let verticalSpacing: CGFloat
    /// 列数按“卡片至少这么宽”自然计算，再夹在最小／最大列数之间。
    package let minimumCardWidth: CGFloat
    package let minimumColumnCount: Int
    package let maximumColumnCount: Int
    /// 卡片宽度对应的卡片高度。
    private let cardHeight: @Sendable (CGFloat) -> CGFloat

    package init(
        contentPadding: CGFloat,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat,
        minimumCardWidth: CGFloat,
        minimumColumnCount: Int,
        maximumColumnCount: Int,
        height: @escaping @Sendable (_ forWidth: CGFloat) -> CGFloat
    ) {
        self.contentPadding = contentPadding
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.minimumCardWidth = minimumCardWidth
        self.minimumColumnCount = minimumColumnCount
        self.maximumColumnCount = maximumColumnCount
        cardHeight = height
    }

    /// 排得下最小列数、每张卡片至少 1pt 宽的最窄视口；更窄时网格不布局、骨架不画。
    package var minimumRenderableWidth: CGFloat {
        contentPadding * 2 + horizontalSpacing * CGFloat(minimumColumnCount - 1)
            + CGFloat(minimumColumnCount)
    }

    package func height(forWidth width: CGFloat) -> CGFloat {
        cardHeight(width)
    }

    package func isRenderableViewport(width: CGFloat) -> Bool {
        width.isFinite && width >= minimumRenderableWidth
    }

    package func columnCount(for width: CGFloat) -> Int {
        let usableWidth = max(0, width - contentPadding * 2)
        let naturalCount = Int(
            (usableWidth + horizontalSpacing) / (minimumCardWidth + horizontalSpacing)
        )
        return min(maximumColumnCount, max(minimumColumnCount, naturalCount))
    }

    package func itemSize(for width: CGFloat) -> CGSize {
        let usableWidth = max(1, width - contentPadding * 2)
        let count = columnCount(for: width)
        let spacing = CGFloat(count - 1) * horizontalSpacing
        let cardWidth = max(1, floor((usableWidth - spacing) / CGFloat(count)))
        return CGSize(width: cardWidth, height: height(forWidth: cardWidth))
    }

    /// 网格内容的总高度；`bottomInset` 是调用方在末行下方为悬浮控件（页码条）额外留出的高度，布局的 section
    /// 底边距与这里取同一个值。
    package func contentHeight(
        for width: CGFloat,
        itemCount: Int,
        bottomInset: CGFloat = 0
    ) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        let columns = columnCount(for: width)
        let rows = (itemCount + columns - 1) / columns
        return Self.topContentPadding
            + CGFloat(rows) * itemSize(for: width).height
            + CGFloat(rows - 1) * verticalSpacing
            + contentPadding
            + bottomInset
    }

    /// 加载骨架的占位卡片数：可见区域能放下的张数与来源已知的本页条数取较小者。
    ///
    /// 可见区域能放下的张数：列数与真实网格相同，行数向上取整，露出一半的那一行也画出来。行数是
    /// `contentHeight` 行高公式的反解，高度刚好容纳整行时不多画；只露出行间距时多画一行，这一行在视野外，
    /// 不可见。宽度不足以排出网格（真实网格此时也不布局）或高度不是正的有限值时为 0：首次布局常给出零尺寸，
    /// 下一次布局拿到真实尺寸后再铺满。
    ///
    /// `expectedItemCount` 是来源已知的本页条数，nil 表示不知道、铺满：内容少的来源加载完不会突然少掉一大片骨架。
    /// 0 与负数按 0 张，加载中留空，随后出现空态。
    package func placeholderCount(for size: CGSize, expectedItemCount: Int? = nil) -> Int {
        guard
            isRenderableViewport(width: size.width),
            size.height.isFinite,
            size.height > 0
        else { return 0 }
        let rowStride = itemSize(for: size.width).height + verticalSpacing
        let rows = max(
            1,
            Int(ceil((size.height - Self.topContentPadding + verticalSpacing) / rowStride))
        )
        let fillCount = rows * columnCount(for: size.width)
        guard let expectedItemCount else { return fillCount }
        return min(fillCount, max(0, expectedItemCount))
    }
}
