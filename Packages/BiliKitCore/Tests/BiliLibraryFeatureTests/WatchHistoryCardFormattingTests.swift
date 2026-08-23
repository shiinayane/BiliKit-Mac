import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliLibraryFeature

struct WatchHistoryCardFormattingTests {
    @Test
    func loadedAndLoadingMoreProjectToTheSameStableSurface() {
        let item = WatchHistoryItem(
            bvid: "BV1HistorySurface",
            title: "历史卡片",
            coverURL: nil,
            owner: VideoOwner(id: 7, name: "历史作者"),
            progressSeconds: 65,
            durationSeconds: 600,
            viewedAt: .now
        )
        let continuation = WatchHistoryContinuation(rawValue: "opaque")
        let loaded = WatchHistoryLoadedSurface(
            state: .loaded(
                items: [item],
                continuation: continuation,
                loadMoreError: nil
            ),
            requiresManualLoadMore: false
        )
        let loadingMore = WatchHistoryLoadedSurface(
            state: .loadingMore(items: [item], continuation: continuation),
            requiresManualLoadMore: false
        )
        let retry = WatchHistoryLoadedSurface(
            state: .loaded(
                items: [item],
                continuation: continuation,
                loadMoreError: .transportFailure
            ),
            requiresManualLoadMore: false
        )

        #expect(loaded?.items == loadingMore?.items)
        #expect(loaded?.canLoadMore == true)
        #expect(loadingMore?.canLoadMore == true)
        #expect(loaded?.isLoadingMore == false)
        #expect(loadingMore?.isLoadingMore == true)
        #expect(retry?.loadMoreError == .transportFailure)
    }

    @Test
    func manualContinuationKeepsCardsButDisablesAutomaticNearEnd() {
        let item = WatchHistoryItem(
            bvid: "BV1HistoryManual",
            title: "历史卡片",
            coverURL: nil,
            owner: VideoOwner(id: 7, name: "历史作者"),
            progressSeconds: 65,
            durationSeconds: 600,
            viewedAt: .now
        )
        let surface = WatchHistoryLoadedSurface(
            state: .loaded(
                items: [item],
                continuation: WatchHistoryContinuation(rawValue: "opaque"),
                loadMoreError: nil
            ),
            requiresManualLoadMore: true
        )

        #expect(surface?.items == [item])
        #expect(surface?.canLoadMore == true)
        #expect(surface?.requiresManualLoadMore == true)
        #expect(surface?.isLoadingMore == false)
    }

    @Test
    func nativePresentationMapsCurrentHistorySlotsAndAccessibility() {
        let item = WatchHistoryItem(
            bvid: "BV1HistorySlot",
            title: "历史卡片",
            coverURL: URL(string: "https://i0.hdslb.com/cover.jpg"),
            owner: VideoOwner(
                id: 7,
                name: "历史作者",
                avatarURL: nil
            ),
            progressSeconds: 65,
            durationSeconds: 600,
            viewedAt: .now
        )

        let presentation = WatchHistoryCardPresentation(item: item)

        #expect(presentation.bvid == "BV1HistorySlot")
        #expect(presentation.title == "历史卡片")
        #expect(
            presentation.coverURL?.absoluteString.hasSuffix("@640w_360h_1c.webp") == true
        )
        #expect(presentation.avatarURL == nil)
        #expect(!presentation.showsAvatar)
        #expect(presentation.progressText == "1:05/10:00")
        #expect(presentation.footerLeadingText == "历史作者")
        #expect(presentation.accessibilityLabel.contains("观看进度 1:05/10:00"))
    }

    @Test
    func historyImagesUseBoundedCDNVariantsWithoutRewritingUnknownOrigins() throws {
        let trusted = WatchHistoryCardPresentation(
            item: WatchHistoryItem(
                bvid: "BV1HistoryImages",
                title: "历史图片",
                coverURL: URL(string: "https://i0.hdslb.com/cover.jpg"),
                owner: VideoOwner(
                    id: 7,
                    name: "作者",
                    avatarURL: URL(string: "https://i1.hdslb.com/avatar.jpg")
                ),
                progressSeconds: 1,
                durationSeconds: 10,
                viewedAt: .now
            )
        )
        let unknownURL = try #require(URL(string: "https://images.example/avatar.jpg"))
        let unknown = WatchHistoryCardPresentation(
            item: WatchHistoryItem(
                bvid: "BV1HistoryUnknown",
                title: "未知图片源",
                coverURL: unknownURL,
                owner: VideoOwner(id: 8, name: "作者", avatarURL: unknownURL),
                progressSeconds: 1,
                durationSeconds: 10,
                viewedAt: .now
            )
        )

        #expect(trusted.coverURL?.absoluteString.hasSuffix("@640w_360h_1c.webp") == true)
        #expect(trusted.avatarURL?.absoluteString.hasSuffix("@96w_96h_1c.webp") == true)
        #expect(unknown.coverURL == unknownURL)
        #expect(unknown.avatarURL == unknownURL)
    }

    @Test
    func historyImageOptimizationRejectsAmbiguousOrAlreadyTransformedURLs() throws {
        let values = try [
            #require(URL(string: "https://evilhdslb.com/avatar.jpg")),
            #require(URL(string: "https://i0.hdslb.com/avatar.jpg?token=public")),
            #require(URL(string: "https://i0.hdslb.com/avatar.jpg#fragment")),
            #require(URL(string: "https://i0.hdslb.com/avatar.jpg@48w_48h.webp")),
        ]

        for (index, url) in values.enumerated() {
            let presentation = WatchHistoryCardPresentation(
                item: WatchHistoryItem(
                    bvid: "BV1HistoryGuard\(index)",
                    title: "图片边界",
                    coverURL: url,
                    owner: VideoOwner(id: Int64(index), name: "作者", avatarURL: url),
                    progressSeconds: 1,
                    durationSeconds: 10,
                    viewedAt: .now
                )
            )

            #expect(presentation.coverURL == url)
            #expect(presentation.avatarURL == url)
        }
    }

    @Test
    func progressShowsElapsedDurationOrCompletedState() {
        #expect(
            WatchHistoryCardFormatting.progress(
                progressSeconds: 65,
                durationSeconds: 600
            ) == "1:05/10:00"
        )
        #expect(
            WatchHistoryCardFormatting.progress(
                progressSeconds: 3_661,
                durationSeconds: 7_322
            ) == "1:01:01/2:02:02"
        )
        #expect(
            WatchHistoryCardFormatting.progress(
                progressSeconds: 600,
                durationSeconds: 600
            ) == "已看完"
        )
        #expect(
            WatchHistoryCardFormatting.progress(
                progressSeconds: 0,
                durationSeconds: 0
            ) == "0:00/0:00"
        )
    }

    @Test
    func viewedAtFollowsInjectedLocale() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(
            TimeZone(identifier: "Asia/Tokyo")
        )
        let now = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 24,
                    hour: 13
                )
            )
        )
        let today = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 24,
                    hour: 9,
                    minute: 5
                )
            )
        )
        let yesterday = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 23,
                    hour: 22,
                    minute: 7
                )
            )
        )
        let older = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 20,
                    hour: 8,
                    minute: 3
                )
            )
        )

        #expect(
            WatchHistoryCardFormatting.viewedAt(
                today,
                now: now,
                calendar: calendar,
                locale: Locale(identifier: "zh-Hans")
            ) == "今天 9:05"
        )
        #expect(
            WatchHistoryCardFormatting.viewedAt(
                yesterday,
                now: now,
                calendar: calendar,
                locale: Locale(identifier: "zh-Hans")
            ) == "昨天 22:07"
        )
        #expect(
            WatchHistoryCardFormatting.viewedAt(
                older,
                now: now,
                calendar: calendar,
                locale: Locale(identifier: "zh-Hans")
            ) == "7月20日 8:03"
        )
    }
}
