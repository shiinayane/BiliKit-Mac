import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation
import SwiftUI

/// 已有详情时的播放页主区：播放器、相关推荐横排，以及工具栏标题、副标题、点赞投币收藏一组、发送弹幕与弹幕设置按钮。
struct VideoDetailView<PlayerContent: View>: View {
    @Environment(\.locale) private var locale
    let context: VideoContext
    let danmakuModel: DanmakuControlsViewModel
    let danmakuComposer: DanmakuComposerModel?
    let engagementModel: VideoEngagementModel
    let relatedVideoState: RelatedVideoState
    let onSelectRelatedVideo: (String) -> Void
    let onRetryRelatedVideos: () -> Void
    let relatedImageLoader: any NativeVideoImageLoading
    let playerContent: () -> PlayerContent

    var body: some View {
        PlaybackDetailLayout {
            player
        } related: {
            RelatedVideoShelf(
                state: shelfState,
                onSelect: onSelectRelatedVideo,
                onRetry: onRetryRelatedVideos,
                contentIdentity: context.detail.bvid,
                imageLoader: relatedImageLoader
            )
        }
        .navigationTitle(context.detail.title)
        .navigationSubtitle(toolbarSubtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                VideoEngagementControls(model: engagementModel)
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

    /// 工具栏副标题：播放 · 弹幕 · 发布时间，有访问限制时接上充电／试看提示。
    private var toolbarSubtitle: String {
        let statistics = context.detail.statistics
        return [
            VideoMetadataFormatting.viewCountText(statistics.viewCount),
            VideoMetadataFormatting.danmakuCountText(statistics.danmakuCount),
            VideoMetadataFormatting.fullPublishedDate(context.detail.publishedAt),
            accessNotice
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private var accessNotice: String? {
        switch context.accessNotice {
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
    }
}
