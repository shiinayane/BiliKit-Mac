import CoreGraphics

/// 资料库以 sheet 呈现的勾选面板（「收藏到…」「设置分组…」）共用的几何：两个面板是同一种东西，尺寸一致。
enum LibraryPanelGeometry {
    static let width: CGFloat = 360
    /// 列表区固定高度：约十行，再多就在列表内滚动，面板尺寸不随读取状态跳动。
    static let listHeight: CGFloat = 320
    static let padding: CGFloat = 16
    static let headerSpacing: CGFloat = 8
    /// 一行里的条数与名称之间、底栏说明与按钮之间的间距。
    static let itemSpacing: CGFloat = 12
}
