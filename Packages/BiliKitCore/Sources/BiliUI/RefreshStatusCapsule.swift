import SwiftUI

/// 原地刷新时盖在内容顶部的状态胶囊：刷新中显示转圈，失败时显示原因，已显示的内容保持不动。
///
/// 首页推荐、热门、搜索、观看历史、稍后再看与收藏夹共用，出现与消失按 `LoadingStateTransition` 淡入淡出。
/// 失败原因出现时通告给读屏：刷新在后台完成，读屏焦点停在网格里，不会经过顶部胶囊。刷新中的转圈不通告，
/// 结果很快就到，每次刷新都报会盖过结果本身。
package struct RefreshStatusCapsule: View {
    private typealias Geometry = StatusCapsuleGeometry

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let isRefreshing: Bool
    private let refreshingLabel: String
    private let errorMessage: String?

    package init(isRefreshing: Bool, refreshingLabel: String, errorMessage: String?) {
        self.isRefreshing = isRefreshing
        self.refreshingLabel = refreshingLabel
        self.errorMessage = errorMessage
    }

    package var body: some View {
        ZStack {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .padding(Geometry.contentPadding)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityLabel(refreshingLabel)
                    .revealsAfterLoadingDelay()
                    .transition(.opacity)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .padding(Geometry.contentPadding)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Geometry.horizontalInset)
        .animation(LoadingStateTransition.animation(reduceMotion: reduceMotion), value: phase)
        .accessibilityAnnouncement(announcement, trigger: announcement)
    }

    /// 只有失败原因要通告；刷新中为 nil，所以重试后再次失败时同一句话也会再报一次。
    package var announcement: String? {
        isRefreshing ? nil : errorMessage
    }

    private var phase: LoadingVisualPhase {
        if isRefreshing { return .loading }
        return errorMessage == nil ? .idle : .failure
    }
}
