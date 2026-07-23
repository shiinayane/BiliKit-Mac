import BiliApplication
import BiliModels
import SwiftUI

public struct WatchHistoryView: View {
    private let model: WatchHistoryViewModel
    private let onSelect: (String) -> Void
    private let onAuthenticationRequired: () -> Void

    public init(
        model: WatchHistoryViewModel,
        onSelect: @escaping (String) -> Void,
        onAuthenticationRequired: @escaping () -> Void
    ) {
        self.model = model
        self.onSelect = onSelect
        self.onAuthenticationRequired = onAuthenticationRequired
    }

    public var body: some View {
        content
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

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView("正在加载观看历史…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("history.loading")
        case let .loaded(items, continuation, loadMoreError):
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
        case let .loadingMore(items, _):
            historyList(
                items: items,
                canLoadMore: true,
                isLoadingMore: true,
                loadMoreError: nil
            )
        case let .failed(error):
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
        List {
            ForEach(items) { item in
                Button {
                    onSelect(item.bvid)
                } label: {
                    WatchHistoryRow(item: item)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("history.item.\(item.bvid)")
            }

            if let loadMoreError {
                Text(message(for: loadMoreError))
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("history.list")
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
        case let .serviceRejected(code):
            "服务暂时无法完成请求（代码 \(code)）。"
        case .transportFailure:
            "请检查网络连接后重试。"
        case .invalidResponse:
            "接口数据与当前客户端预期不一致。"
        }
    }
}

private struct WatchHistoryRow: View {
    let item: WatchHistoryItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: item.coverURL) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 144, height: 81)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(item.owner.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(progressText)
                    Spacer()
                    Text(
                        item.viewedAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    private var progressText: String {
        "看到 \(format(item.progressSeconds)) / \(format(item.durationSeconds))"
    }

    private func format(_ seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = seconds % 3_600 / 60
        let seconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
