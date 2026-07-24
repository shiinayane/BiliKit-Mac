import BiliApplication
import BiliModels
import BiliUI
import Foundation
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
                        .buttonStyle(
                            VideoCardButtonStyle(isSelected: false)
                        )
                        .accessibilityHint("播放视频")
                        .accessibilityIdentifier("history.item.\(item.bvid)")
                    }
                }
                .padding(VideoCardGridLayout.contentPadding)

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
        case let .serviceRejected(code):
            "服务暂时无法完成请求（代码 \(code)）。"
        case .transportFailure:
            "请检查网络连接后重试。"
        case .invalidResponse:
            "接口数据与当前客户端预期不一致。"
        }
    }
}

private struct WatchHistoryCard: View {
    let item: WatchHistoryItem

    var body: some View {
        VideoCard(
            coverURL: item.coverURL,
            avatarURL: item.owner.avatarURL,
            showsAvatar: item.owner.avatarURL != nil,
            title: item.title,
            coverTrailingText: WatchHistoryCardFormatting.progress(
                progressSeconds: item.progressSeconds,
                durationSeconds: item.durationSeconds
            ),
            footerLeadingText: item.owner.name,
            footerTrailingText: WatchHistoryCardFormatting.viewedAt(
                item.viewedAt
            ),
            isSelected: false
        )
    }
}

enum WatchHistoryCardFormatting {
    static func progress(
        progressSeconds: Int,
        durationSeconds: Int
    ) -> String {
        let duration = max(0, durationSeconds)
        let progress = min(max(0, progressSeconds), duration)
        if duration > 0, progress >= duration {
            return "已看完"
        }
        return "\(durationText(progress))/\(durationText(duration))"
    }

    static func viewedAt(
        _ date: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return String(format: "今天 %02d:%02d", hour, minute)
        }
        if let yesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: now
        ), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(format: "昨天 %02d:%02d", hour, minute)
        }

        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        return String(
            format: "%d月%d日 %02d:%02d",
            month,
            day,
            hour,
            minute
        )
    }

    private static func durationText(_ seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = seconds % 3_600 / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                remainingSeconds
            )
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}
