import AppKit

/// 逻辑偏移从内容起点算起，与 contentInsets 无关；物理偏移是 clip view 的 bounds origin。
///
/// 纵向（网格、侧栏、详情页）传 top／bottom inset，横向（shelf）传 left／right inset。
enum NativeVideoScrollCoordinateSpace {
    static func logicalOffset(
        physicalOffset: CGFloat,
        leadingInset: CGFloat
    ) -> CGFloat {
        max(0, physicalOffset + max(0, leadingInset))
    }

    static func physicalOffset(
        logicalOffset: CGFloat,
        leadingInset: CGFloat
    ) -> CGFloat {
        max(0, logicalOffset) - max(0, leadingInset)
    }

    static func maximumLogicalOffset(
        documentLength: CGFloat,
        viewportLength: CGFloat,
        leadingInset: CGFloat,
        trailingInset: CGFloat
    ) -> CGFloat {
        max(
            0,
            documentLength - viewportLength
                + max(0, leadingInset)
                + max(0, trailingInset)
        )
    }
}

/// NSScrollView 子类在 `layout()` 中用它判断 viewport 尺寸与 contentInsets 是否变化（半点容差）。
struct NativeScrollViewportTracker {
    struct Change {
        let sizeChanged: Bool
        /// insets 变化时为变化前的值。
        let previousInsets: NSEdgeInsets?
    }

    private var lastSize: NSSize?
    private var lastInsets = NSEdgeInsetsZero

    @MainActor
    mutating func update(for scrollView: NSScrollView) -> Change {
        let size = scrollView.contentSize
        let insets = scrollView.contentInsets
        let sizeChanged =
            lastSize.map {
                abs($0.width - size.width) > 0.5 || abs($0.height - size.height) > 0.5
            } ?? true
        if sizeChanged { lastSize = size }
        let insetsChanged =
            abs(insets.top - lastInsets.top) > 0.5
            || abs(insets.left - lastInsets.left) > 0.5
            || abs(insets.bottom - lastInsets.bottom) > 0.5
            || abs(insets.right - lastInsets.right) > 0.5
        guard insetsChanged else {
            return Change(sizeChanged: sizeChanged, previousInsets: nil)
        }
        let previousInsets = lastInsets
        lastInsets = insets
        return Change(sizeChanged: sizeChanged, previousInsets: previousInsets)
    }
}

extension NSScrollView {
    func scrollVertically(toPhysicalOffset offsetY: CGFloat) {
        contentView.scroll(to: NSPoint(x: 0, y: offsetY))
        reflectScrolledClipView(contentView)
    }

    /// contentInsets 变化后保持逻辑纵向位置不变。
    func preserveLogicalVerticalOffset(
        from oldInsets: NSEdgeInsets,
        to newInsets: NSEdgeInsets
    ) {
        let logicalOffset = NativeVideoScrollCoordinateSpace.logicalOffset(
            physicalOffset: contentView.bounds.origin.y,
            leadingInset: oldInsets.top
        )
        scrollVertically(
            toPhysicalOffset: NativeVideoScrollCoordinateSpace.physicalOffset(
                logicalOffset: logicalOffset,
                leadingInset: newInsets.top
            )
        )
    }
}
