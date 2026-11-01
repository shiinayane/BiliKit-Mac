import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 竖向视频行（UP 主空间投稿、相关推荐）的卡片菜单：与视频卡片相同的「添加到稍后再看」「收藏到…」一组加
/// 「拷贝链接」「在浏览器中打开」一组，规则在共用的 `NativeVideoCardMenu.video`。
enum VideoRowCardMenu {
    /// 行都可进入播放；BVID 不合法时没有菜单。
    ///
    /// `openURL` 是从环境取得的系统 `OpenURLAction`，`writing` 是 App 从环境注入的写入口（未登录或复核中时写操作项
    /// 禁用）。
    @MainActor
    static func menu(
        for row: VideoRowPresentation,
        openURL: OpenURLAction,
        writing: VideoCardAccountWriting?
    ) -> NativeVideoCardMenu? {
        NativeVideoCardMenu.video(
            videoID: row.bvid,
            isActivatable: true,
            webPageURL: BVID.webPageURL(row.bvid),
            openURL: openURL,
            writing: writing,
            watchLater: .add
        )
    }
}
