import AppKit
import SwiftUI

/// 进出播放页的页面转场：在 `NavigationSplitView` 两栏的图层上各挂一个 Core Animation 转场，主区推移、侧栏淡入淡出，
/// 再无动画地换页。
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
    /// 转场时长：比系统压栈略快，连续进出播放页时不拖沓。
    ///
    /// 再短推移就看不清方向。返回时播放器在转场结束后才停止，改长会让暂停的旧视频多留一会儿。
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
        guard let anchor,
            let splitView = anchor.enclosingNavigationSplitView(),
            let detail = splitView.arrangedSubviews.first(where: { anchor.isDescendant(of: $0) }),
            let sidebar = splitView.arrangedSubviews.first,
            sidebar !== detail,
            let detailLayer = detail.layer
        else {
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
        if !splitView.isSubviewCollapsed(sidebar), let sidebarLayer = sidebar.layer {
            sidebarLayer.add(Self.transition(nil), forKey: Self.animationKey)
        }
        Self.applyWithoutAnimation(change)
    }

    /// 换页本身不带 SwiftUI 动画：动画全部交给图层转场，页面内的 AppKit 视图不会随布局动画“飞入”。
    private static func applyWithoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    /// 有方向时推移：进入播放页时新页面从右边推入，返回时从左边推回；没有方向时淡入淡出。
    private static func transition(_ direction: AppPageTransition?) -> CATransition {
        let transition = CATransition()
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        switch direction {
        case .push:
            transition.type = .push
            transition.subtype = .fromRight
        case .pop:
            transition.type = .push
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
