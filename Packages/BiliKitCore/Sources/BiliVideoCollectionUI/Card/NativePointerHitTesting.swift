import AppKit

extension NSView {
    /// 窗口在 `windowPoint` 按点击判定时，命中的是不是本视图或它的子视图。
    ///
    /// 卡片悬停与横排翻页按钮的“指针在不在上面”都按它判断，不只看几何范围：播放页的横排伸到侧栏底下，被侧栏盖住的
    /// 部分几何上仍在视图之内，卡片的 tracking area 也照常发进出事件；只看几何会在指针停在侧栏上时给底下的卡片画悬停、
    /// 把翻页按钮留在横排上。从 contentView 的父视图（窗口边框视图）开始判定，与窗口分发点击走同一条路，标题栏与工具栏
    /// 盖住的部分同样不算。
    package func isHitByPointer(atWindowPoint windowPoint: NSPoint) -> Bool {
        guard let contentView = window?.contentView else { return false }
        let root = contentView.superview ?? contentView
        // `hitTest` 收父视图坐标系里的点；边框视图没有父视图，用窗口坐标。
        let point = root.superview?.convert(windowPoint, from: nil) ?? windowPoint
        guard let hit = root.hitTest(point) else { return false }
        return hit === self || hit.isDescendant(of: self)
    }

    /// 窗口当前指针位置是否命中本视图；滚动、布局之后没有鼠标事件时用它重新判断悬停。
    package var isHitByCurrentPointer: Bool {
        guard let window else { return false }
        return isHitByPointer(atWindowPoint: window.mouseLocationOutsideOfEventStream)
    }
}
