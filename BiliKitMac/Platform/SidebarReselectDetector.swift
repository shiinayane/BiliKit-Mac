import AppKit
import SwiftUI

/// 导航侧栏在已选中的行上再点一下时回调；挂在侧栏 `List` 的背景上。
///
/// 系统侧栏列表再点已选中的行不发出选择变化，SwiftUI 手势又只覆盖行里的文字，所以在 AppKit 层看鼠标：按下与抬起都落在
/// 按下之前就已选中的那一行，行内任何位置都算（与 Apple Music 一致）。只认前台 App 的 key 窗口里不带修饰键的单击：
/// 回根页会清掉历史、停掉播放，把后台窗口或别的 App 带到前台的那一下，以及 ⌘、⇧、⌥ 点按与 ⌃ 点按（右键菜单）都不能
/// 触发它。
///
/// 依赖三条在 macOS 27 实测、没有文档保证的系统行为（macOS 15 没有实测）：侧栏 `List` 由 `NSOutlineView` 承载；再点
/// 已选中的行不改选择；outline 自己的鼠标跟踪循环不吞掉 `leftMouseUp`，本地监听照样看到抬起。不成立时只是这个手势
/// 失效，选择与导航照常。
struct SidebarReselectDetector: NSViewRepresentable {
    let onReselect: () -> Void

    func makeNSView(context: Context) -> SidebarReselectDetectorView {
        let view = SidebarReselectDetectorView()
        view.onReselect = onReselect
        return view
    }

    func updateNSView(_ view: SidebarReselectDetectorView, context: Context) {
        view.onReselect = onReselect
    }

    static func dismantleNSView(_ view: SidebarReselectDetectorView, coordinator: ()) {
        view.removeMonitor()
    }
}

/// 持有一个本地鼠标事件监听与两个激活通知的观察：进入窗口时一起装上，离开窗口或拆除时一起移除，同一时刻各至多一个。
///
/// 监听闭包在主线程回调（本地监听只在应用自己的事件循环里调用），通知观察排在主队列上，都只弱引用本视图；按下时记住的
/// outline 也只弱引用。只认本窗口的事件，并要求点中的 outline 在窗口坐标里与本视图相交：本视图铺满侧栏列表的背景，
/// 主区里的列表与它不相交，别的窗口的事件在前面就排除了。
final class SidebarReselectDetectorView: NSView {
    var onReselect: (() -> Void)?
    private var monitor: Any?
    private var activationObservers: [NSObjectProtocol] = []
    /// 本窗口最近一次成为 key 窗口、或 App 最近一次变为前台的时刻（`systemUptime`，与 `NSEvent.timestamp` 同一时钟）。
    ///
    /// 激活与按下谁先送达没有文档保证：带到前台的那一下点击送达时，App 可能已经是前台、窗口也已经是 key。按下的时刻早于
    /// 这个时刻，就说明这一下点击本身引起了激活，不算再点。
    private var lastActivation: TimeInterval = 0
    private weak var pressedOutline: NSOutlineView?
    private var pressedRow: Int?

    /// 只观察事件，不拦截点击。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard let window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        let center = NotificationCenter.default
        let recordActivation: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.lastActivation = ProcessInfo.processInfo.systemUptime }
        }
        activationObservers = [
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main,
                using: recordActivation
            ),
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main,
                using: recordActivation
            )
        ]
    }

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        activationObservers.forEach(NotificationCenter.default.removeObserver)
        activationObservers = []
        pressedOutline = nil
        pressedRow = nil
    }

    private func handle(_ event: NSEvent) {
        guard let window, event.window === window else { return }
        switch event.type {
        case .leftMouseDown:
            pressedOutline = nil
            pressedRow = nil
            guard window.isKeyWindow, NSApp.isActive, event.timestamp > lastActivation,
                event.clickCount == 1,
                event.modifierFlags.isDisjoint(with: [.command, .control, .shift, .option]),
                let outline = sidebarOutline(at: event)
            else { return }
            let row = outline.row(at: outline.convert(event.locationInWindow, from: nil))
            // 只认按下之前就已选中的行；点别的行由列表自己的选择变化处理。
            guard row >= 0, row == outline.selectedRow else { return }
            pressedOutline = outline
            pressedRow = row
        case .leftMouseUp:
            guard let outline = pressedOutline, let row = pressedRow else { return }
            pressedOutline = nil
            pressedRow = nil
            let upRow = outline.row(at: outline.convert(event.locationInWindow, from: nil))
            guard upRow == row, outline.selectedRow == row else { return }
            // 排在列表自己处理这次点击之后。
            DispatchQueue.main.async { [weak self] in self?.onReselect?() }
        default:
            break
        }
    }

    /// 点中的视图向上最近的 `NSOutlineView`，且它的可见区域在窗口坐标里与本视图相交。
    private func sidebarOutline(at event: NSEvent) -> NSOutlineView? {
        guard let contentView = window?.contentView else { return nil }
        // `hitTest` 按约定收父视图坐标系里的点。
        let point =
            contentView.superview?.convert(event.locationInWindow, from: nil)
            ?? event.locationInWindow
        guard let hit = contentView.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, !(current is NSOutlineView) { view = current.superview }
        guard let outline = view as? NSOutlineView else { return nil }
        let outlineFrame = outline.convert(outline.visibleRect, to: nil)
        return outlineFrame.intersects(convert(bounds, to: nil)) ? outline : nil
    }
}
