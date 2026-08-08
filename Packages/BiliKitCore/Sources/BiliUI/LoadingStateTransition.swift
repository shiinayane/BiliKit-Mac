import SwiftUI

/// 主要加载状态共用的克制淡入淡出语言。
package enum LoadingStateTransition {
    package static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.16)
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
