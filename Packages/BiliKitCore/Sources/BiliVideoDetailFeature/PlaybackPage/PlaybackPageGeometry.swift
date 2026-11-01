import CoreGraphics

/// 播放页分栏：双栏时右侧有一列上下文区（相关推荐，或盖在上面的 UP 主空间）；单栏时它收进视频下方的分页。
public enum PlaybackPageColumns: Sendable, Equatable {
    case two
    case single
}

/// 播放页三块（视频、视频下方的详情与评论、右栏）的尺寸规则，唯一来源；`PlaybackPageView` 只按它摆放。
///
/// 规则取自 B 站 iPad 端的实测：只看页面宽高比决定双栏或单栏；双栏时左列占固定比例，视频按 16:9 撑满所在列的宽度，
/// 高度从不被压缩，其余内容都在视频下方。
enum PlaybackPageGeometry {
    /// 双栏时左列（视频与详情）占页面宽度的比例；iPad 在 898–1194pt 宽度下实测都是这个值，没有上下限。
    static let videoColumnFraction: CGFloat = 0.634
    /// 宽高比升到这个值才进入双栏。
    ///
    /// iPad 实测的切换点在 1.35–1.39 之间；14 寸笔记本带导航侧栏时正好落在附近，所以进出用两个值留出滞后，拖侧栏或
    /// 缩放窗口经过切换点时不会来回跳。调低它会让较窄的窗口也分栏。
    static let enterTwoColumnAspectRatio: CGFloat = 1.40
    /// 宽高比降到这个值以下才回到单栏。
    static let leaveTwoColumnAspectRatio: CGFloat = 1.34
    /// 单栏时视频下方分页条的高度。
    static let singleColumnTabBarHeight: CGFloat = 40
    static let separatorThickness: CGFloat = 1

    private static let videoAspectRatio: CGFloat = 16.0 / 9.0

    /// 按页面尺寸与当前分栏给出下一刻的分栏；落在滞后区间内保持当前值。
    static func columns(for size: CGSize, current: PlaybackPageColumns) -> PlaybackPageColumns {
        guard size.width > 0, size.height > 0 else { return current }
        let aspectRatio = size.width / size.height
        switch current {
        case .single:
            return aspectRatio >= enterTwoColumnAspectRatio ? .two : .single
        case .two:
            return aspectRatio < leaveTwoColumnAspectRatio ? .single : .two
        }
    }

    /// 三块的位置；坐标原点在页面左上角，页面从窗口工具栏下方的边缘算起（延伸到工具栏底下）。
    ///
    /// `topInset` 是工具栏压住页面顶部的高度：视频、分页条与详情从它下方开始；双栏时右栏从页面顶边开始、延伸到工具栏
    /// 底下，列表滚动时内容从工具栏下面经过（列表自己按 `automaticallyAdjustsContentInsets` 留出顶部）。宽高比只按
    /// 工具栏下方的可用区域计算。单栏时 `side` 与 `details` 是同一块区域（由分页决定显示哪个），双栏时 `tabBar` 为空。
    struct Frames: Equatable {
        let video: CGRect
        let tabBar: CGRect
        let details: CGRect
        let side: CGRect
        /// 双栏时左右两列之间的竖分隔线，与右栏一样从页面顶边开始；单栏时为空。
        let columnSeparator: CGRect
    }

    /// 工具栏下方的可用区域，分栏判断只看它。
    static func contentSize(for size: CGSize, topInset: CGFloat) -> CGSize {
        CGSize(width: size.width, height: max(0, size.height - topInset))
    }

    static func frames(
        for size: CGSize,
        topInset: CGFloat,
        columns: PlaybackPageColumns
    ) -> Frames {
        let top = min(max(0, topInset), size.height)
        switch columns {
        case .two:
            let columnWidth = (size.width * videoColumnFraction).rounded()
            let videoHeight = min((columnWidth / videoAspectRatio).rounded(), size.height - top)
            let below = top + videoHeight + separatorThickness
            let sideX = columnWidth + separatorThickness
            return Frames(
                video: CGRect(x: 0, y: top, width: columnWidth, height: videoHeight),
                tabBar: CGRect(x: 0, y: top + videoHeight, width: columnWidth, height: 0),
                details: CGRect(
                    x: 0,
                    y: below,
                    width: columnWidth,
                    height: max(0, size.height - below)
                ),
                side: CGRect(
                    x: sideX,
                    y: 0,
                    width: max(0, size.width - sideX),
                    height: size.height
                ),
                columnSeparator: CGRect(
                    x: columnWidth,
                    y: 0,
                    width: separatorThickness,
                    height: size.height
                )
            )
        case .single:
            let videoHeight = min((size.width / videoAspectRatio).rounded(), size.height - top)
            let tabBar = CGRect(
                x: 0,
                y: top + videoHeight,
                width: size.width,
                height: singleColumnTabBarHeight
            )
            let contentY = tabBar.maxY + separatorThickness
            let content = CGRect(
                x: 0,
                y: contentY,
                width: size.width,
                height: max(0, size.height - contentY)
            )
            return Frames(
                video: CGRect(x: 0, y: top, width: size.width, height: videoHeight),
                tabBar: tabBar,
                details: content,
                side: content,
                columnSeparator: .zero
            )
        }
    }
}
