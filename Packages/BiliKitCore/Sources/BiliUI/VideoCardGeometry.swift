import Foundation

/// 视频卡片网格的唯一几何来源：App 的原生网格与 Feature 的加载骨架共用。
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

    public static func contentHeight(for width: CGFloat, itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        let columns = columnCount(for: width)
        let rows = (itemCount + columns - 1) / columns
        return topContentPadding
            + CGFloat(rows) * itemSize(for: width).height
            + CGFloat(rows - 1) * verticalSpacing
            + contentPadding
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
