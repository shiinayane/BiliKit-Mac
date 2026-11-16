import AppKit
import SwiftUI

/// 网格内容顶部的附加视图（整页空间页的头部）：SwiftUI 内容与它的高度。
///
/// 高度与宽度无关，由调用方的几何常量给出（内容各行单行截断）；布局的顶部边距、附加视图的 frame 与近尾判断都用这
/// 一个值，不另外测量。
package struct NativeVideoGridTopAccessory {
    package let height: CGFloat
    package let content: AnyView

    package init(height: CGFloat, content: AnyView) {
        self.height = height
        self.content = content
    }
}

/// 网格可选的装饰：内容顶部的附加视图与右下角的「返回顶部」。
///
/// 来源页都不用，整页空间页两样都用。
package struct NativeVideoGridDecorations {
    package var topAccessory: NativeVideoGridTopAccessory?
    /// 「返回顶部」的读屏名称与提示（调用方已本地化）；nil 时不显示按钮。
    package var scrollToTopLabel: String?

    package static var none: NativeVideoGridDecorations {
        NativeVideoGridDecorations(topAccessory: nil, scrollToTopLabel: nil)
    }

    package init(topAccessory: NativeVideoGridTopAccessory?, scrollToTopLabel: String?) {
        self.topAccessory = topAccessory
        self.scrollToTopLabel = scrollToTopLabel
    }
}

/// 网格装饰的 owner：顶部附加视图的宿主与「返回顶部」按钮。
///
/// 由 `NativeGridView.Coordinator` 持有一份，在建好滚动视图时 `attach`，每次 `update` 交回最新的装饰，`reset()`
/// 时一并拆除。宿主一旦建立就保留到 `reset()`，内容变化只换 `rootView`，其中的 SwiftUI 状态与键盘焦点不丢；读屏顺序由
/// 集合视图把它排在卡片之前（`leadingAccessoryView`）。宿主放在首行上方让出的空间里、按钮点击带动画滚动的理由见
/// docs/ARCHITECTURE.md「原生 AppKit 集合视图」。
@MainActor
final class NativeVideoGridDecorationHost: NSObject {
    /// 首行上方让出的高度：有附加视图时等于它的高度，否则为 0。
    private(set) var topInset: CGFloat = 0
    private var decorations = NativeVideoGridDecorations.none
    /// 点「返回顶部」时调用；由 Coordinator 在建好滚动视图时设置，`reset()` 时清空。
    var onScrollToTop: () -> Void = {}
    private var accessoryHost: NSHostingView<AnyView>?
    private var scrollToTop: NativeScrollToTopButton?
    private weak var collectionView: NativeVideoCollectionView?
    private weak var scrollView: NSScrollView?
    private var isReset = false

    /// 滚动视图建好后由 Coordinator 调用一次：按已交来的装饰装上视图。
    func attach(collectionView: NativeVideoCollectionView, scrollView: NSScrollView) {
        self.collectionView = collectionView
        self.scrollView = scrollView
        installViews()
    }

    /// 交回最新的装饰，返回顶部边距是否变了（变了要失效布局、重排 document）。
    ///
    /// 滚动视图还没建好时只记下，由 `attach` 装上。
    func update(_ decorations: NativeVideoGridDecorations) -> Bool {
        guard !isReset else { return false }
        self.decorations = decorations
        let previousInset = topInset
        topInset = decorations.topAccessory?.height ?? 0
        if collectionView != nil { installViews() }
        return previousInset != topInset
    }

    /// 由网格的滚动视图在 `tile()` 与 `layout()` 时调用：附加视图跟着集合视图的宽度，按钮贴右下角。
    func layout() {
        if let accessoryHost, let collectionView {
            accessoryHost.frame = NSRect(
                x: 0,
                y: 0,
                width: collectionView.bounds.width,
                height: topInset
            )
        }
        if let scrollToTop, let scrollView { scrollToTop.layout(in: scrollView) }
    }

    /// 按逻辑滚动偏移更新「返回顶部」的显隐。
    func updateScrollToTopVisibility(logicalOffset: CGFloat) {
        scrollToTop?.updateVisibility(logicalOffset: logicalOffset, isBlocked: false)
    }

    /// 网格拆除时调用，不可逆：放开附加视图里捕获的模型与闭包，拿掉按钮。
    func reset() {
        guard !isReset else { return }
        isReset = true
        onScrollToTop = {}
        accessoryHost?.rootView = AnyView(EmptyView())
        accessoryHost?.removeFromSuperview()
        accessoryHost = nil
        collectionView?.leadingAccessoryView = nil
        scrollToTop?.button.removeFromSuperview()
        scrollToTop = nil
    }

    private func installViews() {
        installAccessory()
        installScrollToTop()
        layout()
    }

    private func installAccessory() {
        guard let collectionView else { return }
        guard let accessory = decorations.topAccessory else {
            accessoryHost?.removeFromSuperview()
            accessoryHost = nil
            collectionView.leadingAccessoryView = nil
            return
        }
        if let accessoryHost {
            accessoryHost.rootView = accessory.content
            return
        }
        let host = NSHostingView(rootView: accessory.content)
        // frame 只由 `layout()` 按集合视图宽度与 `topInset` 给出：宿主不产生尺寸约束（换 `rootView` 时不牵动窗口约束，
        // detail 列很窄时也不与自动伸缩冲突）、不把内容桥接到窗口的标题与工具栏；头部滚到工具栏下面时不按窗口安全区给
        // 自己加内边距，否则滚动中内容会跳。
        host.sizingOptions = []
        host.sceneBridgingOptions = []
        host.safeAreaRegions = []
        host.autoresizingMask = [.width]
        collectionView.addSubview(host)
        collectionView.leadingAccessoryView = host
        accessoryHost = host
    }

    private func installScrollToTop() {
        guard let scrollView else { return }
        guard let label = decorations.scrollToTopLabel else {
            scrollToTop?.button.removeFromSuperview()
            scrollToTop = nil
            return
        }
        guard scrollToTop == nil else { return }
        let button = NativeScrollToTopButton(label: label)
        button.button.target = self
        button.button.action = #selector(scrollToTopFromButton)
        scrollView.addSubview(button.button)
        scrollToTop = button
    }

    @objc private func scrollToTopFromButton() {
        onScrollToTop()
    }
}
