import SwiftUI

/// 将历史页面可见性连接到 ViewModel 的加载与路由停用语义。
///
/// `.task` 触发并等待模型当前请求。真正的来源 Tab 停用由 App composition 通知模型；
/// 播放详情只是覆盖本页面，不应误取消分页。登出清理仍由窗口级 `reset` 边界负责。
public struct WatchHistoryView<LoadedContent: View>: View {
    private let model: WatchHistoryViewModel
    private let makeLoadedContent:
        (
            [WatchHistoryCardPresentation],
            Bool,
            String?,
            Bool,
            @escaping () -> Void,
            @escaping (String) -> Void
        ) -> LoadedContent
    private let onSelect: (String) -> Void
    private let onAuthenticationRequired: () -> Void

    public init(
        model: WatchHistoryViewModel,
        @ViewBuilder makeLoadedContent:
            @escaping (
                [WatchHistoryCardPresentation],
                Bool,
                String?,
                Bool,
                @escaping () -> Void,
                @escaping (String) -> Void
            ) -> LoadedContent,
        onSelect: @escaping (String) -> Void,
        onAuthenticationRequired: @escaping () -> Void
    ) {
        self.model = model
        self.makeLoadedContent = makeLoadedContent
        self.onSelect = onSelect
        self.onAuthenticationRequired = onAuthenticationRequired
    }

    public var body: some View {
        WatchHistoryContentView(
            model: model,
            makeLoadedContent: makeLoadedContent,
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
    }
}
