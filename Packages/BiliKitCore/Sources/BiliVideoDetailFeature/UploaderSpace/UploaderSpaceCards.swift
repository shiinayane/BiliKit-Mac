import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// UP 主空间投稿的卡片菜单：侧栏预览的投稿行与整页空间页的网格共用。
///
/// 与相关推荐卡片相同的「添加到稍后再看」「收藏到…」一组加「拷贝链接」「在浏览器中打开」一组，规则在共用的
/// `NativeVideoCardMenu.video`。投稿都可进入播放；BVID 不合法时没有菜单。`openURL` 是从环境取得的系统 `OpenURLAction`，
/// `writing` 是 App 从环境注入的写入口（未登录或复核中时写操作项禁用）。
@MainActor
enum UploaderSpaceCardMenu {
    static func menu(
        videoID: String,
        openURL: OpenURLAction,
        writing: VideoCardAccountWriting?
    ) -> NativeVideoCardMenu? {
        NativeVideoCardMenu.video(
            videoID: videoID,
            isActivatable: true,
            webPageURL: BVID.webPageURL(videoID),
            openURL: openURL,
            writing: writing,
            watchLater: .add
        )
    }
}

/// 整页空间页网格的投稿卡片。
///
/// 全是同一位 UP 主的投稿，所以不显示头像与 UP 主名：封面上是播放与弹幕数（统计被隐藏时省略）和时长，页脚是发布时间，
/// 联合投稿后面加「合作」。文字与读屏说明取 `UploaderVideoRowPresentation`，与预览的投稿行一致。
enum UploaderSpacePageCards {
    static func presentation(_ video: UploaderVideo) -> NativeVideoCardPresentation {
        let row = UploaderVideoRowPresentation(video: video)
        let metrics = [
            video.viewCount.map {
                NativeVideoCardMetric(
                    text: VideoMetadataFormatting.compactCount($0),
                    systemImage: "play.fill"
                )
            },
            video.danmakuCount.map {
                NativeVideoCardMetric(
                    text: VideoMetadataFormatting.compactCount($0),
                    systemImage: "text.bubble.fill"
                )
            }
        ].compactMap(\.self)
        let published = VideoMetadataFormatting.publishedDate(video.publishedAt)
        return NativeVideoCardPresentation(
            id: video.bvid,
            title: video.title,
            coverURL: BiliImageThumbnail.url(video.coverURL, size: .videoCover),
            avatarURL: nil,
            showsAvatar: false,
            coverMetrics: metrics,
            coverTrailingText: row.durationText,
            footerLeadingText: video.isCollaboration
                ? "\(published) · \(row.collaborationText)" : published,
            accessibilityLabel: row.accessibilityLabel
        )
    }
}
