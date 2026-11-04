import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation
import SwiftUI
import Testing

@testable import BiliBrowseFeature

/// 首页推荐、热门与搜索的卡片都有「添加到稍后再看」（交出的是这张卡片的 BVID）、「收藏到…」与「拷贝链接」「在浏览器中打开」，打开的是
/// 该视频的网页地址；ID 不是合法 BVID 时没有菜单。
struct BrowseVideoCardMenuTests {
    private static let owner = VideoOwner(id: 1, name: "作者")
    private static let statistics = VideoStatistics(viewCount: 10, danmakuCount: 2, likeCount: 3)
    private static let publishedAt = Date(timeIntervalSince1970: 0)

    @Test @MainActor
    func everyBrowseSourceOffersTheVideoLinks() throws {
        let cards = [
            RecommendedNativeGridView.makePresentation(
                RecommendedVideo(
                    bvid: "BV1Recommended",
                    title: "首页推荐",
                    coverURL: nil,
                    owner: Self.owner,
                    statistics: Self.statistics,
                    durationSeconds: 60,
                    publishedAt: Self.publishedAt,
                    recommendationReason: nil
                ),
                isDisliked: false
            ),
            PopularNativeGridView.makePresentation(
                PopularVideo(
                    bvid: "BV1Popular",
                    title: "热门",
                    coverURL: nil,
                    owner: Self.owner,
                    statistics: Self.statistics,
                    durationSeconds: 60,
                    publishedAt: Self.publishedAt
                )
            ),
            SearchNativeGridView.makePresentation(
                SearchVideoCardPresentation(
                    video: SearchVideo(
                        bvid: "BV1Search",
                        title: "搜索结果",
                        coverURL: nil,
                        owner: Self.owner,
                        statistics: Self.statistics,
                        durationSeconds: 60,
                        publishedAt: Self.publishedAt
                    )
                )
            )
        ]

        for card in cards {
            var opened: [URL] = []
            let writes = RecordedWrites()
            let menu = try #require(
                BrowseVideoCardMenu.menu(
                    for: card,
                    openURL: OpenURLAction { url in
                        opened.append(url)
                        return .handled
                    },
                    writing: writes.writing
                )
            )
            #expect(
                menu.items.map(\.title)
                    == [
                        VideoCardMenuText.addToWatchLater,
                        VideoCardMenuText.addToFavorites,
                        VideoCardMenuText.copyLink,
                        VideoCardMenuText.openInBrowser
                    ]
            )
            menu.items[0].action()
            menu.items[3].action()
            #expect(writes.addedToWatchLater == [card.id])
            #expect(opened.map(\.absoluteString) == ["https://www.bilibili.com/video/\(card.id)"])
        }
    }

    @Test @MainActor
    func cardWithoutAValidBVIDHasNoMenu() throws {
        let card = PopularNativeGridView.makePresentation(
            PopularVideo(
                bvid: "BV-not/valid",
                title: "形状不对",
                coverURL: nil,
                owner: Self.owner,
                statistics: Self.statistics,
                durationSeconds: 60,
                publishedAt: Self.publishedAt
            )
        )

        let openURL = OpenURLAction { _ in .handled }
        #expect(BrowseVideoCardMenu.menu(for: card, openURL: openURL, writing: nil) == nil)
    }
}
