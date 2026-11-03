import AppKit
import SwiftUI

/// 系统侧栏列在两种状态下的宽度范围：浏览时是导航，播放时原地换成详情与评论。
///
/// 是侧栏列宽的唯一来源：`AppShellView` 的 `navigationSplitViewColumnWidth` 与宽度记忆的夹取共用它。
/// 两个范围不重叠，进出播放时系统一定会改动侧栏宽度，`SidebarWidthRestoringView` 依赖这一点在同一次布局里换成记住的宽度。
enum SidebarColumnMode: Equatable {
    case browsing
    case playback

    /// 浏览态下限：最长的固定文字（英文 “Watch history”）连图标与列表边距约 150，再窄开始截断；
    /// 用户拖过下限时系统收起侧栏，所以文字完整的最后一档才收起。
    private static let browsingMinimumWidth: CGFloat = 180
    /// 浏览态默认：约 1290 宽的窗口里详情区仍能排 4 列卡片（网格 4 列需要 1068）；调宽会让常见窗宽少一列。
    private static let browsingIdealWidth: CGFloat = 220
    /// 浏览态上限：收藏夹名较长时可以拖宽，超过后只是空白。
    private static let browsingMaximumWidth: CGFloat = 320
    /// 播放态下限：评论约 25 字一行，与手机评论区宽度相当；笔记本上视频受宽度限制，评论列每宽一点视频就小一点，
    /// 下限决定小屏上视频能有多大（13 英寸屏上 400 时视频约 960–990 宽，520 时只有 840–870）。
    private static let playbackMinimumWidth: CGFloat = 400
    /// 播放态默认：没有记住宽度时第一次进入播放的宽度。
    private static let playbackIdealWidth: CGFloat = 440
    /// 播放态上限：约 56 字一行；只防止拖到失去意义，具体宽度交给用户与宽度记忆。
    private static let playbackMaximumWidth: CGFloat = 840

    var minimumWidth: CGFloat {
        switch self {
        case .browsing: Self.browsingMinimumWidth
        case .playback: Self.playbackMinimumWidth
        }
    }

    var idealWidth: CGFloat {
        switch self {
        case .browsing: Self.browsingIdealWidth
        case .playback: Self.playbackIdealWidth
        }
    }

    var maximumWidth: CGFloat {
        switch self {
        case .browsing: Self.browsingMaximumWidth
        case .playback: Self.playbackMaximumWidth
        }
    }

    func clamped(_ width: CGFloat) -> CGFloat {
        min(maximumWidth, max(minimumWidth, width))
    }
}

/// 用户拖出的侧栏宽度，浏览态与播放态各存一份，所有窗口共用；持久化范围见 SECURITY-MODEL §6。
///
/// 只保存数值，不拥有恢复时机（交给 `SidebarWidthRestoringView`）。
struct SidebarWidthStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 该状态应恢复到的宽度：记住的值夹进当前范围；没有、损坏或非有限值时用该状态的默认宽度。
    func restoredWidth(for mode: SidebarColumnMode) -> CGFloat {
        guard let number = defaults.strictNumber(forKey: Self.key(for: mode)),
            number.doubleValue.isFinite
        else { return mode.idealWidth }
        return mode.clamped(CGFloat(number.doubleValue))
    }

    func record(_ width: CGFloat, for mode: SidebarColumnMode) {
        guard width.isFinite else { return }
        defaults.set(Double(mode.clamped(width)), forKey: Self.key(for: mode))
    }

    private static func key(for mode: SidebarColumnMode) -> String {
        switch mode {
        case .browsing: "sidebarWidth.browsing"
        case .playback: "sidebarWidth.playback"
        }
    }
}

/// 挂在侧栏列内容上，让浏览态与播放态各自记住用户拖出的宽度。
///
/// 调用方必须把它放在侧栏列里、且不随进出播放重建的位置（`AppShellView` 挂在侧栏 ZStack 的背景上）：
/// 它按 `mode` 的变化判断进出播放。
struct SidebarWidthRestorer: NSViewRepresentable {
    let mode: SidebarColumnMode

    func makeNSView(context: Context) -> SidebarWidthRestoringView {
        SidebarWidthRestoringView(mode: mode)
    }

    func updateNSView(_ view: SidebarWidthRestoringView, context: Context) {
        view.update(mode: mode)
    }
}

/// 找到 `NavigationSplitView` 底下的 `NSSplitView`，记录用户拖出的宽度，并在进出播放与启动时恢复。
///
/// 用 AppKit：`NavigationSplitView` 只有固定列宽或 min/ideal/max，没有宽度绑定；系统只在一次运行内记住
/// 一个拖出的宽度，切换状态时按新范围夹取，重启后也不恢复。改 min/max 钉住宽度再放开会被系统打回它记住的值，
/// 所以这里不碰范围，只调用公开的 `setPosition(_:ofDividerAt:)`，系统随后把这个宽度当作用户拖出的宽度保持。
/// 找不到 `NSSplitView`（系统改了视图层级）时什么都不做，退回系统行为。
///
/// 拥有对 split view 的弱引用、一条 `didResizeSubviewsNotification` 观察和待恢复的目标宽度；
/// 离开窗口时移除观察并放弃目标。只在主线程使用。
final class SidebarWidthRestoringView: NSView {
    private let store = SidebarWidthStore()
    private var mode: SidebarColumnMode
    private weak var splitView: NSSplitView?
    /// 进出播放或挂进窗口时设置，恢复到位或兜底那一拍之后清空；清空后不再追着任何 resize 改宽度，
    /// 否则窗口太窄、目标暂时放不下时，之后用户的拖动或缩放会被拉回旧目标。
    private var pendingWidth: CGFloat?
    /// 每次设置目标时递增；兜底那一拍只在代次未变时清空目标，连续进出播放时旧的兜底不会清掉新目标。
    private var restoreGeneration = 0
    /// 自己调用 `setPosition` 期间为真：那几次 resize 回调既不当作用户拖动记录，也不再次恢复。
    private var isApplying = false

    init(mode: SidebarColumnMode) {
        self.mode = mode
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observed = splitView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSSplitView.didResizeSubviewsNotification,
                object: observed
            )
            splitView = nil
            pendingWidth = nil
        }
        guard window != nil, let found = enclosingNavigationSplitView() else { return }
        splitView = found
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(splitViewDidResizeSubviews(_:)),
            name: NSSplitView.didResizeSubviewsNotification,
            object: found
        )
        // 启动时系统给的是默认宽度，换成这个状态记住的宽度。
        scheduleRestore()
    }

    func update(mode newMode: SidebarColumnMode) {
        guard newMode != mode else { return }
        mode = newMode
        scheduleRestore()
    }

    /// 先记下目标：SwiftUI 随后按新范围夹取宽度时会发 resize 通知，在那次回调里同步恢复，夹取后的宽度不会被画出来；
    /// 两拍之后还没到位（这次没有触发 resize，或回调时范围还没更新）再兜底设一次，然后放弃。
    private func scheduleRestore() {
        guard splitView != nil else { return }
        pendingWidth = store.restoredWidth(for: mode)
        restoreGeneration += 1
        let generation = restoreGeneration
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.restoreGeneration == generation else { return }
                self.applyPendingWidth()
                self.pendingWidth = nil
            }
        }
    }

    @objc private func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isApplying, let splitView, let sidebar = splitView.arrangedSubviews.first,
            !splitView.isSubviewCollapsed(sidebar)
        else { return }
        if pendingWidth != nil {
            applyPendingWidth()
            return
        }
        // 只记用户拖分隔条：程序设置位置时通知里也带分隔条序号，但只有拖动时 split view 处于 live resize；
        // 拖窗口边缘缩放时通知不带分隔条序号。
        if notification.userInfo?["NSSplitViewDividerIndex"] != nil, splitView.inLiveResize {
            store.record(sidebar.frame.width, for: mode)
        }
    }

    /// 用户收起侧栏时不恢复：`setPosition` 会把收起的侧栏重新展开，程序不主动改变侧栏的显示状态。
    private func applyPendingWidth() {
        guard let target = pendingWidth, let splitView,
            let sidebar = splitView.arrangedSubviews.first,
            !splitView.isSubviewCollapsed(sidebar)
        else { return }
        guard abs(sidebar.frame.width - target) > 0.5 else {
            pendingWidth = nil
            return
        }
        isApplying = true
        splitView.setPosition(target, ofDividerAt: 0)
        isApplying = false
        // 回调时范围可能还没换成新状态的，被夹住就留着目标，等下一次 resize 或兜底。
        if abs(sidebar.frame.width - target) <= 0.5 {
            pendingWidth = nil
        }
    }

    /// 侧栏列内容向上第一个由 `NSSplitViewController` 管理的 `NSSplitView`，即 `NavigationSplitView` 的两栏。
    private func enclosingNavigationSplitView() -> NSSplitView? {
        var candidate = superview
        while let view = candidate {
            if let splitView = view as? NSSplitView, splitView.delegate is NSSplitViewController {
                return splitView
            }
            candidate = view.superview
        }
        return nil
    }
}
