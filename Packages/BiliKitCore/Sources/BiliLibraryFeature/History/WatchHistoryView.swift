import SwiftUI

/// 将历史页面可见性连接到 ViewModel 的加载与路由停用语义。
///
/// `.task` 触发并等待模型当前请求；离开页面时 `deactivateRoute` 负责取消在途工作，
/// 同时保留已经加载的条目供返回恢复。登出清理仍由窗口级 `reset` 边界负责。
public struct WatchHistoryView: View {
    private let model: WatchHistoryViewModel
    @Binding private var scrollPosition: ScrollPosition
    private let onSelect: (String) -> Void
    private let onAuthenticationRequired: () -> Void

    public init(
        model: WatchHistoryViewModel,
        scrollPosition: Binding<ScrollPosition>,
        onSelect: @escaping (String) -> Void,
        onAuthenticationRequired: @escaping () -> Void
    ) {
        self.model = model
        _scrollPosition = scrollPosition
        self.onSelect = onSelect
        self.onAuthenticationRequired = onAuthenticationRequired
    }

    public var body: some View {
        WatchHistoryContentView(
            model: model,
            scrollPosition: $scrollPosition,
            onSelect: onSelect
        )
        .task {
            model.loadIfNeeded()
            await model.waitForCurrentTask()
        }
        .onChange(of: model.requiresAuthentication) { _, required in
            if required {
                onAuthenticationRequired()
            }
        }
        .onDisappear {
            model.deactivateRoute()
        }
    }
}
