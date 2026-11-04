import AppKit
import BiliUI

/// AppKit 侧栏里加载提示的延迟露出：加载开始后等 `LoadingIndicatorPolicy.presentationDelay` 仍在加载，
/// 才通过 `apply(true)` 显示转圈（及其文字），与 SwiftUI 的 `revealsAfterLoadingDelay()` 同一规则。
///
/// 由所在的内容视图持有，只拥有一个等待露出的 Task 与“是否已露出”；显示什么、怎么排版仍由该视图在
/// `apply` 里决定，露出前后条目高度不变，测量不读它。`setLoading(false)` 取消等待并立即隐藏；条目复用时
/// 调用方在 `reset()` 里走这一支。同一次加载里重复配置（`setLoading(true)` 再来一次）不会重新计时，只把当前
/// 显隐再应用一次。
/// Task 只弱引用自己，视图释放后醒来什么也不做。
@MainActor
final class NativeLoadingReveal {
    private let apply: @MainActor (Bool) -> Void
    private var pendingReveal: Task<Void, Never>?
    private var isRevealed = false

    /// `apply` 在露出与隐藏时各调用一次；它不得反过来调用 `setLoading`。
    init(apply: @escaping @MainActor (Bool) -> Void) {
        self.apply = apply
    }

    func setLoading(_ isLoading: Bool) {
        guard isLoading else {
            pendingReveal?.cancel()
            pendingReveal = nil
            isRevealed = false
            apply(false)
            return
        }
        // 同一次加载里再次配置时不重新计时，但把当前显隐再应用一次：配置时会先隐藏各控件再按状态显示。
        guard pendingReveal == nil, !isRevealed else {
            apply(isRevealed)
            return
        }
        apply(false)
        pendingReveal = Task { [weak self] in
            try? await Task.sleep(for: LoadingIndicatorPolicy.presentationDelay)
            guard !Task.isCancelled, let self else { return }
            self.pendingReveal = nil
            self.isRevealed = true
            self.apply(true)
        }
    }
}

extension NSProgressIndicator {
    /// 侧栏加载提示共用的系统转圈：停止时不绘制，初始隐藏，不作为读屏元素（所在行自己读出加载说明）。
    static func sidebarLoadingSpinner(controlSize: NSControl.ControlSize) -> NSProgressIndicator {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = controlSize
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.setAccessibilityElement(false)
        return spinner
    }

    /// 显示并转动，或停止并隐藏。
    func setSpinning(_ isSpinning: Bool) {
        isHidden = !isSpinning
        if isSpinning {
            startAnimation(nil)
        } else {
            stopAnimation(nil)
        }
    }

    /// 按系统给出的转圈尺寸居中在 `rect` 内；行高由各自的测量决定，转圈不改变行高。
    func centeredFrame(in rect: NSRect) -> NSRect {
        let size = intrinsicContentSize
        return NSRect(
            x: rect.minX + round((rect.width - size.width) / 2),
            y: rect.minY + round((rect.height - size.height) / 2),
            width: size.width,
            height: size.height
        )
    }
}
