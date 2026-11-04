import SwiftUI

/// 列表底部的分页状态胶囊：加载更多时转圈，失败时显示原因与可选重试，需要用户显式继续时显示按钮。
///
/// 首页推荐、热门、搜索、观看历史与稍后再看共用同一种样式（与顶部 `RefreshStatusCapsule` 一致的材质胶囊）。
/// 只负责排版；标签与动作由调用方的 Feature 本地化并提供，是否给重试由调用方按 `isRetryable` 决定。
/// 加载更多失败时把原因通告给读屏：分页在读屏焦点停在网格里时自动发生，底部胶囊不在焦点处。转圈不通告，
/// 每翻一页都报会打断正在读的卡片；「继续加载」按钮是常驻控件，读屏可以像其他按钮一样找到它，也不通告。
package struct PaginationStatusOverlay: View {
    /// 胶囊的状态；`idle` 不显示任何内容。
    package enum Status {
        case idle
        /// `label` 只作为转圈的读屏标签，不占可见宽度。
        case loadingMore(label: String)
        /// `retry` 为 nil 时只说明原因（重试不会改变结果，或已没有下一页）。
        case failed(message: String, retry: (() -> Void)?)
        /// 空页或全重复页之后不自动翻页，由用户点按继续。
        case manualLoadMore(title: String, action: () -> Void)

        /// 只有失败原因要通告；加载中为 nil，所以重试后再次失败时同一句话也会再报一次。
        package var announcement: String? {
            if case .failed(let message, _) = self { return message }
            return nil
        }
    }

    private typealias Geometry = StatusCapsuleGeometry

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    private let status: Status

    package init(_ status: Status) {
        self.status = status
    }

    package var body: some View {
        ZStack {
            switch status {
            case .idle:
                EmptyView()
            case .loadingMore(let label):
                ProgressView()
                    .controlSize(.small)
                    .padding(Geometry.contentPadding)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityLabel(label)
                    .revealsAfterLoadingDelay()
                    .transition(.opacity)
            case .failed(let message, let retry):
                HStack(spacing: Geometry.spacing) {
                    Text(message)
                        .lineLimit(Geometry.messageLineLimit)
                    if let retry {
                        Button(BiliUIStrings.localized("重试", locale: locale), action: retry)
                    }
                }
                .font(.caption)
                .padding(Geometry.contentPadding)
                .background(.regularMaterial, in: Capsule())
                .transition(.opacity)
            case .manualLoadMore(let title, let action):
                Button(title, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(Geometry.contentPadding)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Geometry.horizontalInset)
        .padding(.bottom, Geometry.bottomInset)
        .animation(LoadingStateTransition.animation(reduceMotion: reduceMotion), value: phase)
        .accessibilityAnnouncement(status.announcement, trigger: status.announcement)
    }

    private var phase: LoadingVisualPhase {
        switch status {
        case .idle: .idle
        case .loadingMore: .loading
        case .failed: .failure
        case .manualLoadMore: .content
        }
    }
}
