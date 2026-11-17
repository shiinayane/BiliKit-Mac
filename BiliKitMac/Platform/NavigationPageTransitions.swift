import AppKit
import SwiftUI

/// 右侧换页（压一层、返回、回到来源）与侧栏上下文层（UP 主空间预览）进出的转场。
///
/// 在 `NavigationSplitView` 两栏的图层上挂 Core Animation 转场，再无动画地换内容：换页时主区覆盖或揭开、侧栏淡入淡出；
/// 上下文层进出时只有侧栏左右推。
///
/// 每个窗口一份，由 `WindowComposition` 构造并以闭包交给 `AppNavigationCoordinator`；只弱引用锚点视图，分栏在每次转场时
/// 从锚点向上临时查找，不持有分栏或观察。每次转场起一个兜底计时的 Task，不保存也不取消：它只持有这次的一次性完成
/// 回调，到时至多调用一次；关窗后才到的完成由协调器丢弃（没有待执行的停止）。为什么用图层转场、不用 SwiftUI 自带
/// 转场或自己拍快照，见 docs/ARCHITECTURE.md「播放页布局」。
///
/// 依赖一个实测、没有文档保证的时序：转场加在当前隐式 Core Animation 事务上，SwiftUI 在同一轮 run loop 里、这个事务
/// 提交之前落地换页，转场因此截到换页前后的两个状态。调用方若在显式的 `CATransaction` 或 `NSAnimationContext` 分组里
/// 调用，或者其间有人 `CATransaction.flush()`，转场截到的前后状态相同，只是没有动画，完成回调照常到达。
@MainActor
final class NavigationPageTransitions {
    /// 转场时长：比系统压栈略快，连续压栈、返回时不拖沓。
    ///
    /// 再短就看不清新页从右边盖上、旧页向右揭开的方向。返回时播放器在转场结束后才停止，改长会让暂停的旧视频多留一会儿。
    private static let duration: CFTimeInterval = 0.3
    /// 两栏转场共用的 key：转场进行中再次导航时替换在途的转场，不叠加。
    private static let animationKey = "BiliKitPageTransition"
    /// 转场结束回调的兜底时限：过了这么久还没回调就照样完成，返回时延后的停止最多晚这么久。
    ///
    /// 窗口在转场中被隐藏、最小化或分栏图层被换掉时，Core Animation 是否仍回调没有文档保证。比转场时长多留余量：太短
    /// 会在转场还在跑时停止播放，旧页面的画面在半路变黑。
    private static let completionDeadline: TimeInterval = duration + 0.5

    weak var anchor: NSView?

    /// 先在两栏挂转场，再同步执行 `change`；转场结束（被下一次转场替换也算结束）后调用 `completion` 一次，最迟在
    /// `completionDeadline` 之后。
    ///
    /// 两栏按锚点认：锚点所在的那一栏是主区，第一栏是侧栏，分栏里多出别的栏也不会把转场挂错。找不到分栏或主区没有
    /// 图层时不加动画，直接换页并立即完成；侧栏收起时只跳过侧栏的转场。打开「减少动态效果」时主区也只淡入淡出。
    func perform(
        _ direction: AppPageTransition,
        change: () -> Void,
        completion: @escaping () -> Void
    ) {
        guard let (splitView, sidebar, detail) = columns(), let detailLayer = detail.layer else {
            Self.applyWithoutAnimation(change)
            completion()
            return
        }
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let detailTransition = Self.transition(reducesMotion ? nil : direction)
        let finish = TransitionCompletion(completion)
        detailTransition.delegate = finish
        detailLayer.add(detailTransition, forKey: Self.animationKey)
        Task { @MainActor [finish] in
            try? await Task.sleep(for: .seconds(Self.completionDeadline))
            finish.finish()
        }
        // 换页的侧栏淡入淡出刻意挂在那一栏的外层：换页大多同时改变侧栏宽度（浏览类与播放页各记各的宽度），外层的淡入
        // 把玻璃底的宽度变化也一起淡过去，比较柔和；代价是截不到旧内容（见 `contentLayer(of:)`），旧侧栏不交叉淡出，
        // 只有新侧栏淡入。挂在内容层时内容交叉淡化，但玻璃底的宽度会硬跳。
        if !splitView.isSubviewCollapsed(sidebar), let sidebarLayer = sidebar.layer {
            sidebarLayer.add(Self.transition(nil), forKey: Self.animationKey)
        }
        Self.applyWithoutAnimation(change)
    }

    /// 侧栏上下文层的进出：只在侧栏挂 `push` 转场再无动画地换内容；打开时新层从右边推进来，关闭时原来的侧栏从左边推回来，
    /// 「减少动态效果」时淡入淡出。
    ///
    /// 用 `push` 不用主区的 `moveIn`／`reveal`：侧栏是半透明材质，新旧两层叠着滑会互相透出，`push` 让两层一起平移、互不
    /// 重叠。找不到分栏或侧栏收起时直接换。不等结束回调：上下文层进出不牵涉播放的停止。
    func performSidebarContext(_ direction: AppPageTransition, change: () -> Void) {
        guard let (splitView, sidebar, _) = columns(),
            !splitView.isSubviewCollapsed(sidebar),
            let sidebarLayer = Self.contentLayer(of: sidebar)
        else {
            Self.applyWithoutAnimation(change)
            return
        }
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let transition = Self.transition(nil)
        if !reducesMotion {
            transition.type = .push
            transition.subtype = direction == .push ? .fromRight : .fromLeft
        }
        sidebarLayer.add(transition, forKey: Self.animationKey)
        Self.applyWithoutAnimation(change)
    }

    /// 从锚点临时找到分栏与两栏：锚点所在的那一栏是主区，第一栏是侧栏；找不到分栏或侧栏就是主区时为 nil。
    private func columns() -> (splitView: NSSplitView, sidebar: NSView, detail: NSView)? {
        guard let anchor,
            let splitView = anchor.enclosingNavigationSplitView(),
            let detail = splitView.arrangedSubviews.first(where: { anchor.isDescendant(of: $0) }),
            let sidebar = splitView.arrangedSubviews.first,
            sidebar !== detail
        else { return nil }
        return (splitView, sidebar, detail)
    }

    /// 侧栏一栏里能截到内容新旧两个状态的那一层，上下文层的推用它。
    ///
    /// macOS 26 起侧栏内容包在 `NSGlassEffectView` 里，挂在玻璃视图或它外面那一栏上的转场截不到内容的旧状态：被推走的
    /// 一层是空的，看起来只有新内容在动。挂在玻璃视图的 `contentView` 上才截得到；上下文层进出不改侧栏宽度，挂在这里
    /// 没有玻璃底硬跳的问题。更早的系统没有玻璃视图，用那一栏本身。
    private static func contentLayer(of sidebar: NSView) -> CALayer? {
        if #available(macOS 26.0, *),
            let glass = sidebar.firstDescendant(ofType: NSGlassEffectView.self),
            let contentLayer = glass.contentView?.layer
        {
            return contentLayer
        }
        return sidebar.layer
    }

    /// 换页本身不带 SwiftUI 动画：动画全部交给图层转场，页面内的 AppKit 视图不会随布局动画“飞入”。
    private static func applyWithoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    /// 有方向时滑动，没有时淡入淡出。
    ///
    /// 移动的页叠在不动的那一页上：压一层时新页从右边盖上去，返回时旧页向右滑走、露出下面的页面。这要求历史页都铺
    /// 不透明底色，否则叠着滑会透出下面那一页（见 ARCHITECTURE「播放页布局」）。
    private static func transition(_ direction: AppPageTransition?) -> CATransition {
        let transition = CATransition()
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        switch direction {
        case .push:
            transition.type = .moveIn
            transition.subtype = .fromRight
        case .pop:
            transition.type = .reveal
            transition.subtype = .fromLeft
        case nil:
            transition.type = .fade
        }
        return transition
    }
}

/// 主区转场的完成回调，只调用一次：转场结束、被同 key 的下一次转场替换，或兜底时限到了，先到的那个调用。
///
/// Core Animation 强持有动画代理直到动画结束，实践中在主线程回调（文档没有保证）；隔离在主 actor 上，万一不在主线程
/// 回调，Swift 的执行者检查会让它确定地崩溃，而不是静默地数据竞争。
@MainActor
private final class TransitionCompletion: NSObject, CAAnimationDelegate {
    private var completion: (() -> Void)?

    init(_ completion: @escaping () -> Void) {
        self.completion = completion
    }

    func finish() {
        let completion = self.completion
        self.completion = nil
        completion?()
    }

    func animationDidStop(_ animation: CAAnimation, finished flag: Bool) {
        finish()
    }
}

/// 把所在的 AppKit 视图登记为窗口页面转场的锚点；挂在 detail 列的背景上，转场时从它向上找分栏。
struct NavigationPageTransitionAnchor: NSViewRepresentable {
    let transitions: NavigationPageTransitions

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        transitions.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        transitions.anchor = view
    }
}

extension NSView {
    /// 广度优先找第一个指定类型的后代视图（不含自己）。
    fileprivate func firstDescendant<View: NSView>(ofType type: View.Type) -> View? {
        var queue = subviews
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let match = view as? View { return match }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}
