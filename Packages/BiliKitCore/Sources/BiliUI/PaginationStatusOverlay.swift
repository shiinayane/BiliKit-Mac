import SwiftUI

/// 列表底部的分页状态胶囊：加载更多时转圈，失败时显示原因与可选重试，需要用户显式继续时显示按钮。
///
/// 首页推荐、热门、搜索、观看历史、稍后再看、关注页与 UP 主空间页共用，外观与顶部 `RefreshStatusCapsule` 同一来源
/// （`statusCapsuleChrome()`）。
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

        /// 胶囊会停留、需要写入结果胶囊让开：失败与「继续加载」。
        ///
        /// 加载更多的转圈不算：它几乎每翻一页都出现、很快消失，算进去写入结果胶囊会随翻页上下跳；短暂被盖住的只是转圈。
        var holdsLane: Bool {
            switch self {
            case .failed, .manualLoadMore: true
            case .idle, .loadingMore: false
            }
        }

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
                    .statusCapsuleChrome()
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
                .statusCapsuleChrome()
                .transition(.opacity)
            case .manualLoadMore(let title, let action):
                Button(title, action: action)
                    .buttonStyle(.borderedProminent)
                    .statusCapsuleChrome()
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Geometry.horizontalInset)
        .padding(.bottom, Geometry.bottomInset)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PaginationStatusLaneHeightKey.self,
                    value: status.holdsLane ? proxy.size.height : 0
                )
            }
        }
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

/// 底部分页胶囊此刻占去的高度（含它与列表底边的距离）；没有停留的胶囊（`Status.holdsLane`）时为 0。
///
/// 由 `PaginationStatusOverlay` 上报；App 的详情栏据此把写入结果胶囊抬到它上方（`AccountWriteStatusCapsule` 的
/// `bottomClearance`），两颗胶囊不叠在同一位置。详情栏只渲染栈顶那一页，被盖住的页面不在视图树里，不会上报。
public struct PaginationStatusLaneHeightKey: PreferenceKey {
    public static var defaultValue: CGFloat { 0 }

    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
