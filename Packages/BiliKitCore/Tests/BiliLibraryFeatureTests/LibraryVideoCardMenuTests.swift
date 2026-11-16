import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation
import SwiftUI
import Testing

@testable import BiliLibraryFeature

/// 观看历史与收藏夹里可以播放的卡片有「添加到稍后再看」，稍后再看页的卡片有「从稍后再看移除」（带 ⌘⌫），之后是「收藏到…」
/// 与「拷贝链接」「在浏览器中打开」；收藏夹页的视频条目另有「从此收藏夹移除」（带 ⌘⌫），失效的也能移除；稍后再看里失效的
/// 视频只能移除，其他不可用卡片与 ID 不是 BVID、也没有移除动作的收藏条目没有菜单。
struct LibraryVideoCardMenuTests {
    @Test @MainActor
    func playableCardsOfferTheirWatchLaterActionAndVideoLinks() throws {
        let cases: [(NativeVideoCardPresentation, NativeVideoCardMenu.WatchLaterAction, String)] = [
            (
                WatchHistoryCardPresentation(item: item("BV1History")).nativeCard, .add,
                VideoCardMenuText.addToWatchLater
            ),
            (
                WatchLaterCardPresentation(item: laterItem("BV1Later")).nativeCard, .remove,
                VideoCardMenuText.removeFromWatchLater
            ),
            (
                FavoriteCardPresentation(item: favoriteItem("BV1Favorite")).nativeCard, .add,
                VideoCardMenuText.addToWatchLater
            )
        ]

        for (card, action, writeTitle) in cases {
            var opened: [URL] = []
            let writes = RecordedWrites()
            let menu = try #require(
                LibraryVideoCardMenu.menu(
                    for: card,
                    openURL: OpenURLAction { url in
                        opened.append(url)
                        return .handled
                    },
                    writing: writes.writing,
                    watchLater: action
                )
            )
            #expect(
                menu.items.map(\.title)
                    == [
                        writeTitle, VideoCardMenuText.addToFavorites, VideoCardMenuText.copyLink,
                        VideoCardMenuText.openInBrowser
                    ]
            )
            menu.items[0].action()
            menu.items[1].action()
            menu.items[3].action()
            #expect(
                writes.events == [
                    "\(action == .add ? "add" : "remove") \(card.id)", "choose \(card.id)"
                ]
            )
            #expect(opened.map(\.absoluteString) == ["https://www.bilibili.com/video/\(card.id)"])
        }
    }

    /// 稍后再看里失效的视频只剩「从稍后再看移除」，⌘⌫ 执行的就是它。
    @Test @MainActor
    func unavailableWatchLaterItemsCanOnlyBeRemoved() throws {
        let card = WatchLaterCardPresentation(
            item: laterItem("BV1LaterGone", unavailability: .invalid)
        ).nativeCard
        let writes = RecordedWrites()

        let menu = try #require(
            LibraryVideoCardMenu.menu(
                for: card,
                openURL: OpenURLAction { _ in .handled },
                writing: writes.writing,
                watchLater: .remove
            )
        )

        #expect(menu.items.map(\.title) == [VideoCardMenuText.removeFromWatchLater])
        menu.enabledItem(for: .commandDelete)?.action()
        #expect(writes.events == ["remove BV1LaterGone"])
    }

    /// 收藏夹页把显示中的收藏夹与条目的 av 号交给写入口；失效视频（有没有 BVID 都一样）只剩「从此收藏夹移除」。
    @Test @MainActor
    func favoriteFolderEntriesCanBeRemovedFromTheFolder() throws {
        let writes = RecordedWrites()
        let entry = try #require(FavoriteFolderEntry(folderID: 10, videoAID: 170_001))
        let cards = [
            FavoriteCardPresentation(item: favoriteItem("BV1Favorite", videoAID: 170_001))
                .nativeCard,
            FavoriteCardPresentation(
                item: favoriteItem("fav-2-170001", unavailability: .invalid, videoAID: 170_001)
            ).nativeCard
        ]

        let writing = writes.writing
        let removal: @MainActor @Sendable () -> Void = { writing.removeFromFavoriteFolder(entry) }
        let menus = cards.map {
            LibraryVideoCardMenu.menu(
                for: $0,
                openURL: OpenURLAction { _ in .handled },
                writing: writing,
                watchLater: .add,
                removeFromFavoriteFolder: removal
            )
        }

        for menu in menus {
            menu?.enabledItem(for: .commandDelete)?.action()
        }
        #expect(menus[1]?.items.map(\.title) == [VideoCardMenuText.removeFromFavoriteFolder])
        #expect(writes.events == ["unfavorite 170001 from 10", "unfavorite 170001 from 10"])
    }

    @Test @MainActor
    func otherUnavailableCardsAndCardsWithoutABVIDHaveNoMenu() {
        let favoriteGone = favoriteItem("BV1FavoriteGone", unavailability: .invalid)
        let collection = favoriteItem("fav-21-1", unavailability: .collection)
        let cards = [
            FavoriteCardPresentation(item: favoriteGone).nativeCard,
            FavoriteCardPresentation(item: collection).nativeCard
        ]
        let openURL = OpenURLAction { _ in .handled }
        let writes = RecordedWrites()

        for card in cards {
            #expect(
                LibraryVideoCardMenu.menu(
                    for: card,
                    openURL: openURL,
                    writing: writes.writing,
                    watchLater: .add
                ) == nil
            )
        }
    }
}

/// 记录写入口收到的意图；闭包在主线程调用。
@MainActor
private final class RecordedWrites {
    var events: [String] = []

    var writing: VideoCardAccountWriting {
        VideoCardAccountWriting(
            isAvailable: { true },
            addToWatchLater: { [weak self] in self?.events.append("add \($0)") },
            removeFromWatchLater: { [weak self] in self?.events.append("remove \($0)") },
            chooseFavoriteFolders: { [weak self] in self?.events.append("choose \($0)") },
            removeFromFavoriteFolder: { [weak self] in
                self?.events.append("unfavorite \($0.videoAID) from \($0.folderID)")
            },
            dislikeRecommendation: { _ in },
            cancelRecommendationDislike: { _ in },
            followSpecialState: { _ in nil },
            setFollowSpecial: { _, _ in },
            chooseFollowGroups: { _ in },
            unfollow: { _ in }
        )
    }
}
