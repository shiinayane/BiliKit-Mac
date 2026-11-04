import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation
import SwiftUI

/// 热门的已加载网格：把热门条目映射为原生卡片，交给共享的 `NativeVideoGridView`；用 AppKit 网格的理由见
/// ARCHITECTURE「原生 AppKit 集合视图」。
///
/// 只负责映射与接线：分页与选择意图回送 `PopularFeedView` 给出的回调，卡片菜单取 `BrowseVideoCardMenu`，
/// 滚动位置、回顶请求与取图 port 来自 App 窗口的 `NativeVideoGridHostContext`。
struct PopularNativeGridView: View {
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @Environment(\.videoCardAccountWriting) private var accountWriting
    let content: LoadedFeedContent<PopularVideo>
    let host: NativeVideoGridHostContext
    /// 卡片展示数据按位置缓存，翻页时只格式化新追加的条目，见 `NativeVideoCardCache`。
    @State private var cards = NativeVideoCardCache<PopularVideo>()

    var body: some View {
        NativeVideoGridView(
            items: cards.cards(for: content.items, make: { Self.makePresentation($0) }),
            accessibilityLabel: BrowseFeatureStrings.localized("热门视频", locale: locale),
            tailState: content.tailState,
            host: host,
            onNearEnd: content.loadMore,
            onSelect: content.select,
            cardMenu: {
                BrowseVideoCardMenu.menu(for: $0, openURL: openURL, writing: accountWriting)
            }
        )
    }

    /// 条目已由 `PagedVideoList` 按 BVID 去重，卡片 ID 因此唯一。
    static func makePresentation(
        _ video: PopularVideo,
        locale: Locale = InterfaceLocale.current
    ) -> NativeVideoCardPresentation {
        let presentation = PopularVideoCardPresentation(video: video, locale: locale)
        return NativeVideoCardPresentation(
            id: presentation.bvid,
            title: presentation.title,
            coverURL: presentation.coverURL,
            avatarURL: presentation.avatarURL,
            showsAvatar: true,
            coverMetrics: [
                NativeVideoCardMetric(
                    text: presentation.viewCountText,
                    systemImage: "play.fill"
                ),
                NativeVideoCardMetric(
                    text: presentation.danmakuCountText,
                    systemImage: "text.bubble.fill"
                )
            ],
            coverTrailingText: presentation.durationText,
            footerLeadingText: presentation.footerText,
            accessibilityLabel: presentation.accessibilityLabel
        )
    }
}
