import Foundation

/// 视频卡片网格的唯一几何来源：BiliVideoCollectionUI 的原生网格（`NativeVideoGridView`）与 BiliUI
/// 的加载骨架共用。
public enum VideoCardGridGeometry {
    public static let horizontalSpacing: CGFloat = 20
    public static let verticalSpacing: CGFloat = 28
    public static let contentPadding: CGFloat = 24
    public static let topContentPadding: CGFloat = 0
    /// 列数按“卡片至少这么宽”自然计算，再夹在最小／最大列数之间。
    public static let minimumCardWidth: CGFloat = 240
    public static let minimumColumnCount = 2
    public static let maximumColumnCount = 5
    public static let minimumRenderableWidth = contentPadding * 2 + horizontalSpacing + 2

    public static func isRenderableViewport(width: CGFloat) -> Bool {
        width.isFinite && width >= minimumRenderableWidth
    }

    public static func columnCount(for width: CGFloat) -> Int {
        let usableWidth = max(0, width - contentPadding * 2)
        let naturalCount = Int(
            (usableWidth + horizontalSpacing) / (minimumCardWidth + horizontalSpacing)
        )
        return min(maximumColumnCount, max(minimumColumnCount, naturalCount))
    }

    public static func itemSize(for width: CGFloat) -> CGSize {
        let usableWidth = max(1, width - contentPadding * 2)
        let count = columnCount(for: width)
        let spacing = CGFloat(count - 1) * horizontalSpacing
        let cardWidth = max(1, floor((usableWidth - spacing) / CGFloat(count)))
        return CGSize(width: cardWidth, height: VideoCardGeometry.height(forWidth: cardWidth))
    }

    /// 网格内容的总高度；`bottomInset` 是调用方在末行下方为悬浮控件（页码条）额外留出的高度，布局的 section
    /// 底边距与这里取同一个值。
    public static func contentHeight(
        for width: CGFloat,
        itemCount: Int,
        bottomInset: CGFloat = 0
    ) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        let columns = columnCount(for: width)
        let rows = (itemCount + columns - 1) / columns
        return topContentPadding
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
    package static func placeholderCount(for size: CGSize, expectedItemCount: Int? = nil) -> Int {
        guard
            isRenderableViewport(width: size.width),
            size.height.isFinite,
            size.height > 0
        else { return 0 }
        let rowStride = itemSize(for: size.width).height + verticalSpacing
        let rows = max(
            1,
            Int(ceil((size.height - topContentPadding + verticalSpacing) / rowStride))
        )
        let fillCount = rows * columnCount(for: size.width)
        guard let expectedItemCount else { return fillCount }
        return min(fillCount, max(0, expectedItemCount))
    }
}

/// 单张卡片的 16:9 封面与文字区；纵向偏移都从封面底边算起。
public enum VideoCardGeometry {
    public static let coverAspectWidth: CGFloat = 16
    public static let coverAspectHeight: CGFloat = 9
    public static let coverCornerRadius: CGFloat = 10
    public static let textTopSpacing: CGFloat = 10
    public static let avatarSize: CGFloat = 34
    public static let avatarTextSpacing: CGFloat = 10
    public static let titleHeight: CGFloat = 47
    public static let footerTopOffset: CGFloat = 63
    public static let footerHeight: CGFloat = 21
    public static let textAreaHeight = footerTopOffset + footerHeight

    public static func coverHeight(forWidth width: CGFloat) -> CGFloat {
        floor(width * coverAspectHeight / coverAspectWidth)
    }

    public static func height(forWidth width: CGFloat) -> CGFloat {
        coverHeight(forWidth: width) + textAreaHeight
    }

    public static func textLeadingInset(showsAvatar: Bool) -> CGFloat {
        showsAvatar ? avatarSize + avatarTextSpacing : 0
    }
}
