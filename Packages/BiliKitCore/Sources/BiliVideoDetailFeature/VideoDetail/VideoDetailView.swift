import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation
import SwiftUI

/// 已有详情时的播放页主区：播放器、下方横排（`PlaybackShelf`），以及工具栏标题、副标题和两组按钮：点赞投币收藏一组，
/// 发送弹幕与弹幕设置一组。
///
/// macOS 26 起相邻的工具栏项会并进同一块玻璃，两组之间用固定宽度的 `ToolbarSpacer` 断开；更早的系统每项各自独立，
/// 不需要分隔。
struct VideoDetailView<PlayerContent: View>: View {
    @Environment(\.locale) private var locale
    let context: VideoContext
    /// 充电专属或试看提示；取决于播放清单，开播前为 nil，副标题这时不带这一项。
    let accessNotice: PlaybackAccessNotice?
    let danmakuModel: DanmakuControlsViewModel
    let danmakuComposer: DanmakuComposerModel?
    let engagementModel: VideoEngagementModel
    let relatedVideoState: RelatedVideoState
    let onSelectRelatedVideo: (String) -> Void
    let onRetryRelatedVideos: () -> Void
    /// 选集投影；视频不属于合集时为 nil，横排没有「合集」分页。
    let collectionShelf: PlaybackSelectionProjection?
    /// 正在呈现的分 P 的分段章节；没有章节时为 nil，横排没有「章节」分页。
    let chapterShelf: ChapterShelfInput?
    /// 正在呈现的分 P 的「正在看」人数文本（`VideoOnlineViewerModel`）；没有时副标题不带这一项。
    let onlineViewerText: String?
    let recentlyWatched: [RecentlyWatchedVideo]
    let isReplacingVideo: Bool
    let onSelectRecentlyWatched: (PlaybackSelectionIntent) -> Void
    let onSelectCollectionEpisode: (VideoCollectionEpisodeIdentity) -> Void
    let relatedImageLoader: any NativeVideoImageLoading
    /// 旧详情不可操作时挡住播放器的点击。
    ///
    /// 只挂在播放器上：挂在整页上时 SwiftUI 会给 AppKit 横排临时套一层不传递安全区的
    /// 容器，横排的前缘边距在换视频途中归零又恢复，卡片左右跳一下；横排自己按 `isEnabled` 拦截点击、悬停与菜单。
    let blocksPlayerHitTesting: Bool
    let playerContent: () -> PlayerContent

    var body: some View {
        PlaybackDetailLayout {
            player
        } related: {
            PlaybackShelf(
                collection: collectionShelf,
                chapters: chapterShelf,
                recentlyWatched: recentlyWatched,
                isReplacingVideo: isReplacingVideo,
                relatedState: shelfState,
                relatedContentIdentity: context.detail.bvid,
                onSelectRelated: onSelectRelatedVideo,
                onRetryRelated: onRetryRelatedVideos,
                onSelectRecent: onSelectRecentlyWatched,
                onSelectEpisode: onSelectCollectionEpisode,
                imageLoader: relatedImageLoader
            )
        }
        .navigationTitle(context.detail.title)
        .navigationSubtitle(toolbarSubtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                VideoEngagementControls(model: engagementModel)
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            if let danmakuComposer {
                ToolbarItem(placement: .primaryAction) {
                    DanmakuPostButton(composer: danmakuComposer)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                DanmakuControlsView(model: danmakuModel)
            }
        }
    }

    private var shelfState: RelatedVideoShelfState {
        switch relatedVideoState {
        case .idle, .loading:
            .loading
        case .loaded(let bvid, let videos) where bvid == context.detail.bvid:
            .loaded(
                videos.map { RelatedVideoCardPresentation(video: $0) }
            )
        case .empty(let bvid) where bvid == context.detail.bvid:
            .empty
        case .failed(let bvid, _) where bvid == context.detail.bvid:
            .failure
        case .loaded, .empty, .failed:
            .loading
        }
    }

    /// 工具栏副标题：播放 · 弹幕 · 发布时间，有访问限制时接上充电／试看提示，最后是「正在看」人数。
    ///
    /// 「正在看」排在最后：它比详情晚到、之后还会刷新，放在别的项前面会在出现与变化时把后面各项推来推去；读不到时这一项
    /// 不出现。
    private var toolbarSubtitle: String {
        let statistics = context.detail.statistics
        return [
            VideoMetadataFormatting.viewCountText(statistics.viewCount),
            VideoMetadataFormatting.danmakuCountText(statistics.danmakuCount),
            VideoMetadataFormatting.fullPublishedDate(context.detail.publishedAt),
            accessNoticeText,
            onlineViewerText.map {
                String(
                    format: VideoDetailFeatureStrings.localized("%@ 人正在看", locale: locale),
                    locale: locale,
                    $0
                )
            }
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private var accessNoticeText: String? {
        switch accessNotice {
        case .none:
            return nil
        case .upowerExclusive:
            return VideoDetailFeatureStrings.localized("充电专属", locale: locale)
        case .upowerPreview(let previewDurationSeconds, let fullDurationSeconds):
            let preview = VideoDurationFormatting.string(seconds: previewDurationSeconds)
            let full = VideoDurationFormatting.string(seconds: fullDurationSeconds)
            let durationNotice = String(
                format: VideoDetailFeatureStrings.localized(
                    "可试看至 %@ / 完整视频 %@",
                    locale: locale
                ),
                locale: locale,
                preview,
                full
            )
            return [
                VideoDetailFeatureStrings.localized("充电专属", locale: locale),
                durationNotice
            ].joined(separator: " · ")
        }
    }

    private var player: some View {
        playerContent()
            .background(.black)
            .allowsHitTesting(!blocksPlayerHitTesting)
    }
}
