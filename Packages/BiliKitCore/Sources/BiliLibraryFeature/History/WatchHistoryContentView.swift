import BiliApplication
import BiliModels
import BiliUI
import SwiftUI

struct WatchHistoryLoadedSurface: Equatable {
    let items: [WatchHistoryItem]
    let canLoadMore: Bool
    let isLoadingMore: Bool
    let requiresManualLoadMore: Bool
    let loadMoreError: WatchHistoryError?

    init?(state: WatchHistoryState, requiresManualLoadMore: Bool) {
        switch state {
        case .loaded(let items, let continuation, let loadMoreError)
        where !items.isEmpty:
            self.items = items
            canLoadMore = continuation != nil
            isLoadingMore = false
            self.requiresManualLoadMore = requiresManualLoadMore
            self.loadMoreError = loadMoreError
        case .loadingMore(let items, _):
            self.items = items
            canLoadMore = true
            isLoadingMore = true
            self.requiresManualLoadMore = false
            loadMoreError = nil
        case .idle, .loading, .loaded, .failed:
            return nil
        }
    }
}

struct WatchHistoryContentView<LoadedContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: WatchHistoryViewModel
    let makeLoadedContent:
        (
            [WatchHistoryCardPresentation],
            Bool,
            String?,
            Bool,
            @escaping () -> Void,
            @escaping (String) -> Void
        ) -> LoadedContent
    let onSelect: (String) -> Void

    var body: some View {
        ZStack {
            content
                .transition(.opacity)
        }
        .animation(
            LoadingStateTransition.animation(reduceMotion: reduceMotion),
            value: visualPhase
        )
    }

    @ViewBuilder
    private var content: some View {
        if let surface = WatchHistoryLoadedSurface(
            state: model.state,
            requiresManualLoadMore: model.requiresManualLoadMore
        ) {
            historyList(
                items: surface.items,
                canLoadMore: surface.canLoadMore,
                isLoadingMore: surface.isLoadingMore,
                requiresManualLoadMore: surface.requiresManualLoadMore,
                loadMoreError: surface.loadMoreError
            )
        } else {
            switch model.state {
            case .idle, .loading:
                VideoCardGridSkeleton(loadingLabel: "正在加载观看历史")
            case .loaded(_, let continuation, let loadMoreError):
                emptyHistory(
                    canLoadMore: continuation != nil,
                    loadMoreError: loadMoreError
                )
            case .failed(let error):
                failure(error)
            case .loadingMore:
                EmptyView()
            }
        }
    }

    private var visualPhase: LoadingVisualPhase {
        switch model.state {
        case .idle, .loading:
            .loading
        case .loaded(let items, _, _) where items.isEmpty:
            .empty
        case .loaded, .loadingMore:
            .content
        case .failed:
            .failure
        }
    }

    private func emptyHistory(
        canLoadMore: Bool,
        loadMoreError: WatchHistoryError?
    ) -> some View {
        ContentUnavailableView {
            Label("暂无可显示的观看历史", systemImage: "clock.arrow.circlepath")
        } description: {
            if let loadMoreError {
                Text(message(for: loadMoreError))
            } else if canLoadMore {
                Text("当前页没有普通视频记录，可以继续检查更早的历史。")
            } else {
                Text("在哔哩哔哩观看过的普通视频会显示在这里。")
            }
        } actions: {
            if canLoadMore {
                Button("加载更早的记录") {
                    model.loadMore()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func historyList(
        items: [WatchHistoryItem],
        canLoadMore: Bool,
        isLoadingMore: Bool,
        requiresManualLoadMore: Bool,
        loadMoreError: WatchHistoryError?
    ) -> some View {
        ZStack(alignment: .bottom) {
            makeLoadedContent(
                items.map(WatchHistoryCardPresentation.init),
                canLoadMore && !requiresManualLoadMore,
                model.paginationTailIdentity,
                isLoadingMore,
                model.loadMore,
                onSelect
            )

            if isLoadingMore {
                ProgressView("正在加载更早的记录…")
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 8)
                    .transition(.opacity)
            } else if let loadMoreError {
                HStack(spacing: 12) {
                    Text(message(for: loadMoreError))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if canLoadMore {
                        Button("重试", action: model.loadMore)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
                .transition(.opacity)
            } else if requiresManualLoadMore {
                Button("加载更早的记录", action: model.loadMore)
                    .buttonStyle(.borderedProminent)
                    .padding(10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 8)
            }
        }
    }

    private func failure(_ error: WatchHistoryError) -> some View {
        ContentUnavailableView {
            Label(title(for: error), systemImage: "exclamationmark.triangle")
        } description: {
            Text(message(for: error))
        } actions: {
            if error != .authenticationRequired {
                Button("重试") {
                    model.reload()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func title(for error: WatchHistoryError) -> String {
        switch error {
        case .authenticationRequired:
            "登录状态已失效"
        case .requestRestricted:
            "请求受到限制"
        default:
            "无法加载观看历史"
        }
    }

    private func message(for error: WatchHistoryError) -> String {
        switch error {
        case .authenticationRequired:
            "请重新扫码登录后再试。"
        case .requestRestricted:
            "服务暂时拒绝了请求，请降低频率后重试。"
        case .serviceRejected(let code):
            "服务暂时无法完成请求（代码 \(code)）。"
        case .transportFailure:
            "请检查网络连接后重试。"
        case .invalidResponse:
            "接口数据与当前客户端预期不一致。"
        }
    }
}
