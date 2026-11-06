import Foundation

/// 底部悬浮页码条（`PageNumberPager`）的唯一几何来源；列表为它留出的底部高度也在这里，收藏夹网格读同一个值。
package enum PageNumberPagerGeometry {
    /// 页码条显示时列表底部留出的高度，让最后一行不被悬浮的页码条挡住。
    package static let reservedHeight: CGFloat = 60
    static let itemSize: CGFloat = 22
    static let itemSpacing: CGFloat = 2
    static let numberPadding: CGFloat = 3
    static let gapWidth: CGFloat = 16
    static let fieldWidth: CGFloat = 40
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 8
    static let collapsedLabelPadding: CGFloat = 6
    static let bottomInset: CGFloat = 10
    /// 展开时页码从这个比例放大到原尺寸。
    static let expansionScale: CGFloat = 0.6
    static let expansionDuration: Double = 0.28
}
