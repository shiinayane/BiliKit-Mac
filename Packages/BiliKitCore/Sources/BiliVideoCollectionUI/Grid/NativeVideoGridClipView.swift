import AppKit

/// 网格滚动视图的 clip view：差异动画进行中视野原点每移动一次，就让集合视图为新视野补建卡片。
///
/// 拥有进行中的差异动画计数与补建的重入标记；不拥有快照与数据源（归 `NativeGridView.Coordinator`），
/// 也不决定是否做动画（规则见 `NativeVideoGridUpdatePlan.animatesDifferences`）。只由 `NativeGridView` 创建，
/// 装为滚动视图的 `contentView`，document 是网格的集合视图。
///
/// 为什么需要补建：批量更新动画进行中（约 250ms），`NSCollectionView` 不为新露出的区域创建卡片，直到动画结束。
/// 纯原生探针（FlowLayout 与 Compositional、diffable 与经典数据源都一样）里，删除动画中回顶、一次滚出一屏或真实
/// 滚轮事件，视野里都是 0 张卡片，持续约 230–265ms；只滚 0.4 屏时新露出的那一条一直空着。网格在动画中移动视野的
/// 情形有回顶、待恢复偏移、宽度或高度变化后的锚点恢复，以及用户自己的快速滚动。
///
/// 为什么补一次空批量更新可行：无动画的 `performBatchUpdates(nil)` 让集合视图按当前视野重新排定可见卡片，新视野的
/// 卡片在 10ms 内补齐；它不带改动，进行中的位移与淡出照常播放，带动画那次的完成回调时间不变。
///
/// 为什么挂在这两个入口：补建必须在 clip view 移动之后。bounds 变化通知与 `prepareContent(in:)` 里调用都太早，
/// 实测不起作用；下一轮主队列再调用可能空一帧。滚轮、`scroll(to:)` 式的程序定位不经过 `setBoundsOrigin(_:)`，带动画
/// 的滚动、直接设 bounds 不经过 `scroll(to:)`，只覆写其中一个都仍有空白，所以两个都覆写。
@MainActor
final class NativeVideoGridClipView: NSClipView {
    /// 进行中的差异动画数；不为 0 时视野移动就补建。
    ///
    /// Coordinator 在每次带动画的 `apply` 之前调 `beginAnimatedUpdate()` 加一，在那次 `apply` 的完成回调里调
    /// `endAnimatedUpdate()` 减一。
    ///
    /// 用计数而不是布尔：前一次动画未结束又来一次时，先到的完成回调不能把后一次的状态清掉。
    private var animatedUpdateCount = 0
    /// 补建期间为 true：空批量更新可能再次移动 bounds（夹取），重入时不再嵌套。
    private var isRealizingItems = false

    var isAnimatingUpdate: Bool { animatedUpdateCount > 0 }

    func beginAnimatedUpdate() {
        animatedUpdateCount += 1
    }

    func endAnimatedUpdate() {
        animatedUpdateCount = max(0, animatedUpdateCount - 1)
    }

    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: newOrigin)
        realizeItemsDuringAnimatedUpdate()
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(newOrigin)
        realizeItemsDuringAnimatedUpdate()
    }

    private func realizeItemsDuringAnimatedUpdate() {
        guard
            isAnimatingUpdate,
            !isRealizingItems,
            window != nil,
            let collectionView = documentView as? NSCollectionView
        else { return }
        isRealizingItems = true
        defer { isRealizingItems = false }
        collectionView.performBatchUpdates(nil)
    }
}
