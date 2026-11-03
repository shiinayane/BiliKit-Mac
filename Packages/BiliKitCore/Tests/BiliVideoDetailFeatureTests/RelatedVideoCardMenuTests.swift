import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation
import SwiftUI
import Testing

@testable import BiliVideoDetailFeature

/// 相关推荐横排的卡片菜单按卡片 ID 打开该视频的网页地址；ID 不是合法 BVID 时没有菜单；菜单项的组成与禁用规则由
/// BiliVideoCollectionUITests 的 `NativeVideoCardMenuTests` 固定。
struct RelatedVideoCardMenuTests {
    @Test @MainActor
    func relatedCardMenuOpensTheVideoWebPage() throws {
        let card = try #require(
            RelatedNativeShelfView.makePresentations([Self.related("BV1Related")]).first
        )
        var opened: [URL] = []
        let menu = try #require(
            RelatedNativeShelfView.cardMenu(
                for: card,
                openURL: OpenURLAction { url in
                    opened.append(url)
                    return .handled
                },
                writing: VideoCardAccountWriting(
                    isAvailable: { false },
                    addToWatchLater: { _ in },
                    removeFromWatchLater: { _ in },
                    chooseFavoriteFolders: { _ in },
                    removeFromFavoriteFolder: { _ in },
                    dislikeRecommendation: { _ in },
                    cancelRecommendationDislike: { _ in }
                )
            )
        )

        try #require(menu.items.first { $0.title == VideoCardMenuText.openInBrowser }).action()
        #expect(opened.map(\.absoluteString) == ["https://www.bilibili.com/video/BV1Related"])
    }

    @Test @MainActor
    func relatedCardWithoutAValidBVIDHasNoMenu() throws {
        let card = try #require(
            RelatedNativeShelfView.makePresentations([Self.related("BV1 spaced")]).first
        )

        #expect(
            RelatedNativeShelfView.cardMenu(
                for: card,
                openURL: OpenURLAction { _ in .handled },
                writing: nil
            ) == nil
        )
    }

    private static func related(_ bvid: String) -> RelatedVideoCardPresentation {
        RelatedVideoCardPresentation(
            video: RelatedVideo(
                bvid: bvid,
                title: "相关推荐",
                coverURL: nil,
                ownerName: "作者",
                viewCount: 1,
                danmakuCount: 0,
                durationSeconds: 60
            )
        )
    }
}
