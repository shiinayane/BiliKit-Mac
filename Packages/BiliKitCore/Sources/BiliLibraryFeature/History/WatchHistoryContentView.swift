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
    @Environment(\.locale) private var locale
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
                VideoCardGridSkeleton(
                    loadingLabel: LibraryFeatureStrings.localized(
                        "正在加载观看历史",
                        locale: locale
                    )
                )
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
            Label(
                LibraryFeatureStrings.localized("暂无可显示的观看历史", locale: locale),
                systemImage: "clock.arrow.circlepath"
            )
        } description: {
            if let loadMoreError {
                Text(message(for: loadMoreError))
            } else if canLoadMore {
                Text(LibraryFeatureStrings.localized("当前页没有普通视频记录，可以继续检查更早的历史。", locale: locale))
            } else {
                Text(LibraryFeatureStrings.localized("在哔哩哔哩观看过的普通视频会显示在这里。", locale: locale))
            }
        } actions: {
            if canLoadMore {
                Button(LibraryFeatureStrings.localized("加载更早的记录", locale: locale)) {
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
                items.map { WatchHistoryCardPresentation(item: $0, locale: locale) },
                canLoadMore && !requiresManualLoadMore,
                model.paginationTailIdentity,
                isLoadingMore,
                model.loadMore,
                onSelect
            )

            if isLoadingMore {
                ProgressView(LibraryFeatureStrings.localized("正在加载更早的记录…", locale: locale))
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
                        Button(
                            LibraryFeatureStrings.localized("重试", locale: locale),
                            action: model.loadMore
                        )
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
                .transition(.opacity)
            } else if requiresManualLoadMore {
                Button(
                    LibraryFeatureStrings.localized("加载更早的记录", locale: locale),
                    action: model.loadMore
                )
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
                Button(LibraryFeatureStrings.localized("重试", locale: locale)) {
                    model.reload()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func title(for error: WatchHistoryError) -> String {
        switch error {
        case .authenticationRequired:
            LibraryFeatureStrings.localized("登录状态已失效", locale: locale)
        case .requestRestricted:
            LibraryFeatureStrings.localized("请求受到限制", locale: locale)
        default:
            LibraryFeatureStrings.localized("无法加载观看历史", locale: locale)
        }
    }

    private func message(for error: WatchHistoryError) -> String {
        switch error {
        case .authenticationRequired:
            LibraryFeatureStrings.localized("请重新扫码登录后再试。", locale: locale)
        case .requestRestricted:
            LibraryFeatureStrings.localized("服务暂时拒绝了请求，请降低频率后重试。", locale: locale)
        case .serviceRejected(let code):
            LibraryFeatureStrings.localized("服务暂时无法完成请求（代码 \(code)）。", locale: locale)
        case .transportFailure:
            LibraryFeatureStrings.localized("请检查网络连接后重试。", locale: locale)
        case .invalidResponse:
            LibraryFeatureStrings.localized("接口数据与当前客户端预期不一致。", locale: locale)
        }
    }
}
