import SwiftUI

/// 一个来源网格从 App 窗口拿到的依赖：滚动位置、回顶请求、取图 port 与窗口保活里的位置。
///
/// App 窗口（`AppShellView`）按来源持有滚动位置与回顶请求，刷新成功与账户变化时经回顶请求让网格回到顶部；
/// 取图 port 的实现是窗口图片管线。Feature 视图只把它原样交给 `NativeVideoGridView`，不读写其中的状态，
/// 所以只有构造是 `public`。
public struct NativeVideoGridHostContext {
    let scrollOffsetY: Binding<CGFloat>
    let scrollReset: Binding<NativeVideoGridScrollResetState>
    let imageLoader: any NativeVideoImageLoading
    let retention: NativeVideoGridRetention

    public init(
        scrollOffsetY: Binding<CGFloat>,
        scrollReset: Binding<NativeVideoGridScrollResetState>,
        imageLoader: any NativeVideoImageLoading,
        retention: NativeVideoGridRetention
    ) {
        self.scrollOffsetY = scrollOffsetY
        self.scrollReset = scrollReset
        self.imageLoader = imageLoader
        self.retention = retention
    }
}
