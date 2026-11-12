import SwiftUI

/// `NativeVideoGridView` 在 SwiftUI 里的生命周期：Coordinator 向窗口保活要，挂载时交回滚动视图，更新时交回内容与
/// 回调，拆除时保活的摘下、不保活的 `reset()`。
///
/// SwiftUI 对同一视图身份调一次 `makeCoordinator`、一次 `makeNSView`，之后每次重算调 `updateNSView`，离开层级时调
/// `dismantleNSView`；保活容器保证同一 Coordinator 不会同时交给两个视图身份。
extension NativeVideoGridView {
    package func makeCoordinator() -> Coordinator {
        retention.retainer.coordinator(for: retention, make: makeFreshCoordinator)
    }

    private func makeFreshCoordinator() -> Coordinator {
        Coordinator(
            items: items,
            initialScrollOffsetY: scrollOffsetY,
            accessibilityLabel: accessibilityLabel,
            tailState: tailState,
            bottomInset: bottomInset,
            scrollResetRequestID: scrollReset.requestID,
            acknowledgedScrollResetRequestID: scrollReset.acknowledgedRequestID,
            imagePipeline: imagePipeline,
            onScroll: { scrollOffsetY = $0 },
            onAcknowledgeScrollReset: {
                scrollReset.acknowledgedRequestID = $0
            },
            actions: actions
        )
    }

    package func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.attachScrollView()
    }

    package func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(
            items: items,
            accessibilityLabel: accessibilityLabel,
            tailState: tailState,
            bottomInset: bottomInset,
            scrollResetRequestID: scrollReset.requestID,
            requestedScrollOffsetY: scrollOffsetY,
            onScroll: { scrollOffsetY = $0 },
            onAcknowledgeScrollReset: {
                scrollReset.acknowledgedRequestID = $0
            },
            actions: actions
        )
    }

    package static func dismantleNSView(
        _ view: NSScrollView,
        coordinator: Coordinator
    ) {
        if coordinator.isRetained {
            coordinator.detach()
        } else {
            coordinator.reset()
        }
    }
}
