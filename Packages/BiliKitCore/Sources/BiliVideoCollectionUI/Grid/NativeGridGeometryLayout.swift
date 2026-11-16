import AppKit
import BiliUI

/// 原生网格在 `CardGridGeometry` 之上的部分：组合布局的一节与近尾判断按实例的参数算，预备区域与近尾倍数是所有
/// 卡片种类共用的网格策略。
extension CardGridGeometry {
    /// 视野上下各多准备的高度（视野高度的倍数）：卡片提前创建，封面在滚到之前就开始加载。
    ///
    /// 调大会提前创建更多卡片、下载更多封面；调小则封面更晚开始加载，快速滚动时更容易先看到占位。
    static let preparedViewportMultiple: CGFloat = 1
    /// 已准备区域在视野某一侧的余量少于这个倍数的视野高度时刷新（已到内容边缘的一侧除外）。
    ///
    /// 调大会更频繁地重新准备，调小则余量可能在两次刷新之间耗尽。
    static let preparedRefreshViewportMultiple: CGFloat = 0.5
    /// 视野底边离内容底部不足这么多个视野高度时请求下一页，下一页的卡片与封面在滚到之前就绪。
    ///
    /// 调大会更早翻页、多加载用户未必看到的页；调小则快速滚动时可能先到底再等下一页。
    static let nearEndViewportMultiple: CGFloat = 1.5

    /// 视野上下各一屏，夹在内容范围内；不并入系统建议，避免准备区域随滚动越积越大。
    static func preparedContentRect(visible: NSRect, bounds: NSRect) -> NSRect {
        let margin = visible.height * preparedViewportMultiple
        return visible.insetBy(dx: 0, dy: -margin).intersection(bounds)
    }

    /// AppKit 只在视野超出已准备区域时才再次准备；余量不足时由网格主动刷新，保持提前量。
    static func needsPreparedContentRefresh(
        prepared: NSRect,
        visible: NSRect,
        bounds: NSRect
    ) -> Bool {
        let target = preparedContentRect(visible: visible, bounds: bounds)
        guard !target.isEmpty else { return false }
        guard !prepared.isEmpty else { return true }
        let slack = visible.height * preparedRefreshViewportMultiple
        let isShortBelow = prepared.maxY < min(target.maxY, visible.maxY + slack)
        let isShortAbove = prepared.minY > max(target.minY, visible.minY - slack)
        return isShortBelow || isShortAbove
    }

    /// 视野底边是否接近内容底部。
    ///
    /// `extraHeight` 是首行之上与末行之下额外让出的高度（顶部附加视图与底部悬浮控件），
    /// 与 `layoutSection` 的上下边距同源。
    func isNearEnd(
        itemCount: Int,
        width: CGFloat,
        visibleMaximumY: CGFloat,
        viewportHeight: CGFloat,
        extraHeight: CGFloat
    ) -> Bool {
        guard
            itemCount > 0,
            isRenderableViewport(width: width),
            visibleMaximumY.isFinite,
            viewportHeight.isFinite,
            viewportHeight > 0
        else { return false }
        let remaining =
            contentHeight(for: width, itemCount: itemCount, bottomInset: extraHeight)
            - visibleMaximumY
        return remaining < viewportHeight * Self.nearEndViewportMultiple
    }

    /// 网格组合布局的唯一一节：卡片尺寸取 `itemSize(for:)`，与骨架、`contentHeight` 同源。
    ///
    /// `width` 是 section provider 拿到的容器宽度。每行都排满 `columnCount(for:)` 张：卡片宽度向下取整后余下的
    /// 不足一列宽，再放一张至少要多出一个卡片宽加间距，所以组只装得下这么多张；余量经 `.flexible` 间距平均摊进
    /// 列间，首尾贴齐左右边距，不满的末行各张仍在本列的位置。`bottomInset` 加在底边距上、`topInset`（顶部附加视图的
    /// 高度）加在顶边距上，两者之和与 `isNearEnd` 的 `extraHeight` 同源。
    @MainActor
    func layoutSection(
        forWidth width: CGFloat,
        bottomInset: CGFloat,
        topInset: CGFloat
    ) -> NSCollectionLayoutSection {
        let size = itemSize(for: width)
        let item = NSCollectionLayoutItem(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .absolute(size.width),
                heightDimension: .absolute(size.height)
            )
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .absolute(size.height)
            ),
            subitems: [item]
        )
        group.interItemSpacing = NSCollectionLayoutSpacing.flexible(horizontalSpacing)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = verticalSpacing
        section.contentInsets = NSDirectionalEdgeInsets(
            top: Self.topContentPadding + topInset,
            leading: contentPadding,
            bottom: contentPadding + bottomInset,
            trailing: contentPadding
        )
        return section
    }
}
