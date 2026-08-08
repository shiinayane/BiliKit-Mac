import BiliApplication
import BiliModels
import BiliUI
import SwiftUI

struct WatchHistoryContentView: View {
    let model: WatchHistoryViewModel
    @Binding var scrollPosition: ScrollPosition
    let onSelect: (String) -> Void

    @ViewBuilder
    var body: some View {
        switch model.state {
        case .idle, .loading:
            VideoCardGridSkeleton(loadingLabel: "正在加载观看历史")
                .accessibilityIdentifier("history.loading")
        case .loaded(let items, let continuation, let loadMoreError):
            if items.isEmpty {
                emptyHistory(
                    canLoadMore: continuation != nil,
                    loadMoreError: loadMoreError
                )
            } else {
                historyList(
                    items: items,
                    canLoadMore: continuation != nil,
                    isLoadingMore: false,
                    loadMoreError: loadMoreError
                )
            }
        case .loadingMore(let items, _):
            historyList(
                items: items,
                canLoadMore: true,
                isLoadingMore: true,
                loadMoreError: nil
            )
        case .failed(let error):
            failure(error)
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
                .accessibilityIdentifier("history.load-more")
            }
        }
        .accessibilityIdentifier("history.empty")
    }

    private func historyList(
        items: [WatchHistoryItem],
        canLoadMore: Bool,
        isLoadingMore: Bool,
        loadMoreError: WatchHistoryError?
    ) -> some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVGrid(
                    columns: VideoCardGridLayout.columns(
                        for: geometry.size.width
                    ),
                    alignment: .leading,
                    spacing: VideoCardGridLayout.verticalSpacing
                ) {
                    ForEach(items) { item in
                        Button {
                            onSelect(item.bvid)
                        } label: {
                            WatchHistoryCard(item: item)
                        }
                        .buttonStyle(VideoCardButtonStyle())
                        .focusable(false)
                        .accessibilityHint("播放视频")
                        .accessibilityIdentifier("history.item.\(item.bvid)")
                    }
                }
                .padding(VideoCardGridLayout.contentPadding)
                .scrollTargetLayout()

                if let loadMoreError {
                    Text(message(for: loadMoreError))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, VideoCardGridLayout.contentPadding)
                }

                if canLoadMore {
                    HStack {
                        Spacer()
                        Button(isLoadingMore ? "正在加载…" : "加载更多") {
                            model.loadMore()
                        }
                        .disabled(isLoadingMore)
                        .accessibilityIdentifier("history.load-more")
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, VideoCardGridLayout.contentPadding)
                }
            }
            .scrollPosition($scrollPosition)
            .accessibilityIdentifier("history.list")
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
                .accessibilityIdentifier("history.retry")
            }
        }
        .accessibilityIdentifier("history.failure")
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
