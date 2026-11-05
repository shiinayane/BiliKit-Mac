import Foundation

/// 视频卡片菜单项的标题，菜单与读屏「操作」转子共用同一份；各来源不另存译文。
///
/// 菜单的构造在 BiliVideoCollectionUI 的 `NativeVideoCardMenu`，这里只拥有文案。App 的播放器动作菜单也用其中
/// 「拷贝链接」「在浏览器中打开」「添加到稍后再看」三项，所以这三项是 `public`。
public enum VideoCardMenuText {
    public static var copyLink: String { BiliUIStrings.localized("拷贝链接") }
    public static var openInBrowser: String { BiliUIStrings.localized("在浏览器中打开") }
    public static var addToWatchLater: String { BiliUIStrings.localized("添加到稍后再看") }
    package static var removeFromWatchLater: String { BiliUIStrings.localized("从稍后再看移除") }
    package static var addToFavorites: String { BiliUIStrings.localized("收藏到…") }
    package static var removeFromFavoriteFolder: String { BiliUIStrings.localized("从此收藏夹移除") }
    package static var notInterested: String { BiliUIStrings.localized("不感兴趣") }
    package static var undoNotInterested: String { BiliUIStrings.localized("撤销不感兴趣") }
    /// 说过「不感兴趣」的卡片封面角标。
    package static var dislikedBadge: String { BiliUIStrings.localized("将减少此类推荐") }

    /// 子菜单里的一项在读屏操作列表里的名字：带上父项，例如「不感兴趣：此类内容过多」。
    package static func submenuActionTitle(parent: String, child: String) -> String {
        BiliUIStrings.localized("\(parent)：\(child)")
    }
}
