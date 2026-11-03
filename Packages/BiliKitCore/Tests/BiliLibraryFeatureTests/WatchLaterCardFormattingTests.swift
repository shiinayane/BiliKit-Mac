import BiliApplication
import BiliModels
import BiliVideoCollectionUI
import Foundation
import Testing

@testable import BiliLibraryFeature

/// 稍后再看卡片：封面右下角按进度显示“已看完”、进度或时长，页脚是 UP 主与加入时间；番剧／影视、课程与失效
/// 是不可用卡片，角标与读屏标签写出原因。
struct WatchLaterCardFormattingTests {
    @Test(arguments: [
        (WatchLaterProgress.finished, completedText),
        (.watched(seconds: 65), "1:05/10:00"),
        (.notStarted, "10:00")
    ])
    func coverTextFollowsTheProgress(progress: WatchLaterProgress, expected: String) {
        let presentation = WatchLaterCardPresentation(
            item: item(progress: progress),
            locale: Locale(identifier: "zh-Hans")
        )

        #expect(presentation.coverTrailingText == expected)
        #expect(presentation.nativeCard.coverTrailingText == expected)
    }

    @Test
    func footerShowsTheUploaderAndTheAddedTime() throws {
        let locale = Locale(identifier: "zh-Hans")
        let item = item(progress: .notStarted)
        let presentation = WatchLaterCardPresentation(item: item, locale: locale)

        #expect(presentation.footerLeadingText == "稍后作者")
        #expect(
            presentation.footerTrailingText
                == LibraryCardFormatting.timestamp(try #require(item.addedAt), locale: locale)
        )
        #expect(presentation.nativeCard.availability == .available)
    }

    /// 字段不全的不可用条目：占位标题，不显示作者、头像、时长与加入时间，读屏只读标题与原因。
    @Test
    func unavailableItemWithMissingFieldsOmitsThem() {
        let locale = Locale(identifier: "zh-Hans")
        let presentation = WatchLaterCardPresentation(
            item: WatchLaterItem(
                bvid: "BV1LaterGone",
                title: nil,
                coverURL: nil,
                owner: nil,
                durationSeconds: nil,
                progress: .notStarted,
                addedAt: nil,
                unavailability: .invalid
            ),
            locale: locale
        )

        #expect(presentation.title == localized("已失效视频"))
        #expect(presentation.footerLeadingText.isEmpty)
        #expect(!presentation.showsAvatar)
        #expect(presentation.coverTrailingText == nil)
        #expect(presentation.footerTrailingText == nil)
        #expect(
            presentation.accessibilityLabel
                == ListFormatter.localizedString(byJoining: [localized("已失效视频"), localized("已失效")])
        )
    }

    @Test(arguments: [
        (LibraryItemUnavailability.pgc(label: "电影"), "电影"),
        (.pgc(label: nil), localized("番剧")),
        (.course, localized("课程")),
        (.invalid, localized("已失效"))
    ])
    func unavailableItemsShowTheReason(unavailability: LibraryItemUnavailability, reason: String) {
        let presentation = WatchLaterCardPresentation(
            item: item(progress: .notStarted, unavailability: unavailability),
            locale: Locale(identifier: "zh-Hans")
        )

        #expect(presentation.unavailableReason == reason)
        #expect(presentation.nativeCard.availability == .unavailable(badge: reason))
        #expect(presentation.accessibilityLabel.contains(reason))
    }

    private func item(
        progress: WatchLaterProgress,
        unavailability: LibraryItemUnavailability? = nil
    ) -> WatchLaterItem {
        WatchLaterItem(
            bvid: "BV1LaterCard",
            title: "稍后再看卡片",
            coverURL: nil,
            owner: VideoOwner(id: 7, name: "稍后作者"),
            durationSeconds: 600,
            progress: progress,
            addedAt: .now,
            unavailability: unavailability
        )
    }
}

private let completedText = localized("已看完")
