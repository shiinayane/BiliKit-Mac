import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation
import SwiftUI

/// 已有详情时的视频区：播放器，以及工具栏标题、副标题、点赞投币收藏一组与弹幕按钮。
struct VideoDetailView<PlayerContent: View>: View {
    @Environment(\.locale) private var locale
    let context: VideoContext
    let danmakuModel: DanmakuControlsViewModel
    let engagementModel: VideoEngagementModel
    let playerContent: () -> PlayerContent

    var body: some View {
        PlaybackDetailLayout {
            player
        }
        .navigationTitle(context.detail.title)
        .navigationSubtitle(toolbarSubtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                VideoEngagementControls(model: engagementModel)
            }
            ToolbarItem(placement: .primaryAction) {
                DanmakuControlsView(model: danmakuModel)
            }
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
            // 不用 `.background(.black)`：形状样式的背景默认延伸进安全区，视频区紧贴工具栏时会把工具栏底下涂黑。
            .background(.black, ignoresSafeAreaEdges: [])
    }
}
