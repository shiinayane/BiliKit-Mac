import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 播放页右栏的相关推荐竖列：行样式、卡片菜单与原生列表都与 UP 主空间投稿相同（`VideoRowListController`，没有头部）。
///
/// 只读 `VideoViewModel.relatedVideoState`，不拥有请求：加载、失败与重试归视频模型。结果属于别的视频（换视频的
/// 加载期间）时按加载中显示，旧推荐不会留在新视频旁边。点选经 `onSelect` 交给 App 的导航（替换当前视频）。
public struct RelatedVideoColumn: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.videoCardAccountWriting) private var accountWriting
    let model: VideoViewModel
    let imagePipeline: any VideoDetailImageLoading
    let onSelect: (String) -> Void
    /// 被空间层盖住或单栏时在另一个分页：原生列表设 `isHidden`，状态提示也不再可见。
    let isObscured: Bool

    public init(
        model: VideoViewModel,
        imagePipeline: any VideoDetailImageLoading,
        onSelect: @escaping (String) -> Void,
        isObscured: Bool = false
    ) {
        self.model = model
        self.imagePipeline = imagePipeline
        self.onSelect = onSelect
        self.isObscured = isObscured
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel(VideoDetailFeatureStrings.localized("正在加载相关推荐"))
        case .loaded(let bvid, let videos):
            VideoRowListRepresentable(
                content: VideoRowListContent(
                    header: nil,
                    rows: videos.map { VideoRowPresentation(video: $0) },
                    currentBVID: nil,
                    scrollIdentity: bvid,
                    reservesPagerSpace: false
                ),
                imagePipeline: imagePipeline,
                actions: VideoRowListActions(
                    close: {},
                    selectOrder: { _ in },
                    selectVideo: onSelect,
                    cardMenu: { [openURL, accountWriting] row in
                        VideoRowCardMenu.menu(for: row, openURL: openURL, writing: accountWriting)
                    }
                ),
                accessibilityLabel: VideoDetailFeatureStrings.localized("相关推荐"),
                topButtonLabel: VideoDetailFeatureStrings.localized("返回顶部"),
                isObscured: isObscured
            )
            // 双栏时右栏延伸到窗口工具栏底下：列表铺到顶边，内容从工具栏下面滚过，顶部留白由滚动视图自动给出。
            .ignoresSafeArea(.container, edges: .top)
        case .empty:
            Text(VideoDetailFeatureStrings.localized("暂无相关推荐"))
                .foregroundStyle(.secondary)
        case .failure:
            VStack(spacing: 10) {
                Text(VideoDetailFeatureStrings.localized("相关推荐加载失败"))
                    .foregroundStyle(.secondary)
                Button(VideoDetailFeatureStrings.localized("重试"), action: model.retryRelatedVideos)
            }
        }
    }

    private enum ColumnState {
        case loading
        case loaded(bvid: String, videos: [RelatedVideo])
        case empty
        case failure
    }

    /// 只认属于当前展示视频的结果；其余（还没开始、加载中、属于上一个视频）一律按加载中。
    private var state: ColumnState {
        let current = model.presentedContext?.detail.bvid
        switch model.relatedVideoState {
        case .loaded(let bvid, let videos) where bvid == current:
            return videos.isEmpty ? .empty : .loaded(bvid: bvid, videos: videos)
        case .empty(let bvid) where bvid == current:
            return .empty
        case .failed(let bvid, _) where bvid == current:
            return .failure
        case .idle, .loading, .loaded, .empty, .failed:
            return .loading
        }
    }
}
