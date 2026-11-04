import SwiftUI

/// 主要加载状态共用的克制淡入淡出语言。
package enum LoadingStateTransition {
    package static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.16)
    }
}

/// 加载提示的露出时机：加载开始后仍未结束、等过这段时间才露出转圈，见 ARCHITECTURE「加载呈现」。
///
/// 骨架屏不延迟（它占住版面，延迟只会先露出空白）；接续已经露出的转圈也不延迟（播放页三段转圈）。
public enum LoadingIndicatorPolicy {
    /// 多数翻页、换排序与评论请求在这之内返回，不会闪一下转圈；再长就会让慢请求看起来像没有响应。
    ///
    /// SwiftUI 的 `revealsAfterLoadingDelay()`、AppKit 的 `NativeLoadingReveal`、楼中楼提示与播放器浮层都读它。
    public static let presentationDelay: Duration = .milliseconds(300)
}

extension View {
    /// 加载提示（转圈及其旁边的加载说明）等 `LoadingIndicatorPolicy.presentationDelay` 后才露出。
    ///
    /// 计时从这个视图插入开始：调用方只在加载期间插入它，加载结束就移除，下一次加载重新计时。露出前占住
    /// 原本的尺寸、对读屏隐藏，露出时不引起排版变化。
    package func revealsAfterLoadingDelay() -> some View {
        modifier(LoadingDelayedReveal())
    }
}

/// 拥有一次加载提示是否已经露出；`.task` 随视图移除取消，不会在加载结束后才露出。
private struct LoadingDelayedReveal: ViewModifier {
    @State private var isRevealed = false

    func body(content: Content) -> some View {
        content
            .opacity(isRevealed ? 1 : 0)
            .accessibilityHidden(!isRevealed)
            .task {
                try? await Task.sleep(for: LoadingIndicatorPolicy.presentationDelay)
                guard !Task.isCancelled else { return }
                isRevealed = true
            }
    }
}

/// 只表达视觉阶段，不携带内容或请求 identity，避免数据刷新触发整页动画。
package enum LoadingVisualPhase: Equatable {
    case idle
    case loading
    case replacementLoading
    case content
    case empty
    case failure
    case transitioning
}
