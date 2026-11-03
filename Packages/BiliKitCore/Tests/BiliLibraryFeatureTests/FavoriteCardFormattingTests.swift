import BiliApplication
import BiliModels
import BiliVideoCollectionUI
import Foundation
import Testing

@testable import BiliLibraryFeature

/// 收藏夹卡片：封面右下角是时长（0 不显示），页脚是 UP 主与收藏时间（与资料库其他卡片同一格式）；合集、音频、番剧／
/// 影视、未知类型与失效是不可用卡片，角标与读屏标签写出原因，缺的字段省略并用占位标题。
struct FavoriteCardFormattingTests {
    @Test
    func playableCardShowsDurationUploaderAndFavoritedTime() throws {
        let locale = Locale(identifier: "zh-Hans")
        let item = favoriteItem("BV1FavCard")
        let presentation = FavoriteCardPresentation(item: item, locale: locale)
        let favoritedAt = LibraryCardFormatting.timestamp(
            try #require(item.favoritedAt),
            locale: locale
        )

        #expect(presentation.coverTrailingText == "1:40")
        #expect(presentation.footerLeadingText == "测试作者")
        #expect(presentation.footerTrailingText == favoritedAt)
        #expect(presentation.nativeCard.id == "BV1FavCard")
        #expect(presentation.nativeCard.availability == .available)
        #expect(presentation.accessibilityLabel.contains(localized("收藏于 \(favoritedAt)")))
    }

    @Test
    func zeroDurationIsNotShown() {
        let presentation = FavoriteCardPresentation(
            item: FavoriteItem(
                id: "BV1FavZero",
                title: "零时长",
                coverURL: nil,
                owner: VideoOwner(id: 1, name: "作者"),
                durationSeconds: 0,
                favoritedAt: nil
            ),
            locale: Locale(identifier: "zh-Hans")
        )

        #expect(presentation.coverTrailingText == nil)
        #expect(presentation.footerTrailingText == nil)
    }

    @Test(arguments: [
        (LibraryItemUnavailability.collection, localized("合集")),
        (.audio, localized("音频")),
        (.unsupported, localized("不支持")),
        (.pgc(label: "电影"), "电影"),
        (.pgc(label: nil), localized("番剧")),
        (.invalid, localized("已失效"))
    ])
    func unavailableItemsShowTheReason(unavailability: LibraryItemUnavailability, reason: String) {
        let presentation = FavoriteCardPresentation(
            item: favoriteItem("fav-21-1", unavailability: unavailability),
            locale: Locale(identifier: "zh-Hans")
        )

        #expect(presentation.unavailableReason == reason)
        #expect(presentation.nativeCard.availability == .unavailable(badge: reason))
        #expect(presentation.accessibilityLabel.contains(reason))
    }

    @Test
    func unavailableItemWithMissingFieldsOmitsThem() {
        let presentation = FavoriteCardPresentation(
            item: FavoriteItem(
                id: "fav-21-2",
                title: nil,
                coverURL: nil,
                owner: nil,
                durationSeconds: nil,
                favoritedAt: nil,
                unavailability: .invalid
            ),
            locale: Locale(identifier: "zh-Hans")
        )

        #expect(presentation.title == localized("已失效视频"))
        #expect(presentation.footerLeadingText.isEmpty)
        #expect(!presentation.showsAvatar)
        #expect(
            presentation.accessibilityLabel
                == ListFormatter.localizedString(byJoining: [localized("已失效视频"), localized("已失效")])
        )
    }
}
