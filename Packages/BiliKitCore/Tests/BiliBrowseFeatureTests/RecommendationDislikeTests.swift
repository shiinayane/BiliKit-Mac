import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation
import SwiftUI
import Testing

@testable import BiliBrowseFeature

/// 首页推荐的「不感兴趣」只标显示中的条目，撤销只去掉同一份反馈；标记跟着卡片走（刷新后只留仍显示的，加载更多不动），
/// 回滚只作用在改动时的同一份推荐工作集上。
///
/// 标过的卡片留在原位、不可进入播放，菜单只剩「撤销不感兴趣」；没标过的卡片有「不感兴趣」子菜单的两个原因（推荐流没给
/// 追踪 ID 时没有），读屏操作里带上父项的名字。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct RecommendationDislikeTests {
    private static let trackedFixture = ContentFixtures(bvid: "BV17x411w7KC")
    /// 首次加载的第二条、刷新后换上的一条与加载更多带来的一条。
    private static let secondBVID = "BV1RcmdSecond"
    private static let refreshedBVID = "BV1RcmdFresh"
    private static let nextPageBVID = "BV1RcmdNext"

    @Test
    func marksOnlyShownCardsAndUndoesTheSameFeedback() async throws {
        let model = await loadedModel()
        let feedback = try Self.feedback(reason: .content)
        let other = try Self.feedback(reason: .uploader)
        let notShown = try Self.feedback(bvid: "BV1xx411c7mD", reason: .content)

        #expect(model.markRecommendationDisliked(notShown) == nil)
        #expect(model.markRecommendationDisliked(feedback) != nil)
        #expect(model.markRecommendationDisliked(other) == nil)
        #expect(model.unmarkRecommendationDisliked(other) == nil)
        #expect(model.dislikedRecommendations == [feedback.target.bvid: feedback])

        #expect(model.unmarkRecommendationDisliked(feedback) != nil)
        #expect(model.dislikedRecommendations.isEmpty)
    }

    @Test
    func marksFollowTheCardsAcrossLoadMoreAndRefresh() async throws {
        let model = await loadedModel()
        let kept = try Self.feedback(reason: .content)
        let dropped = try Self.feedback(bvid: Self.secondBVID, reason: .uploader)
        #expect(model.markRecommendationDisliked(kept) != nil)
        #expect(model.markRecommendationDisliked(dropped) != nil)

        model.loadMore(.recommendation)
        await model.waitForCurrentTask()
        #expect(BrowseFeed.recommendation.loadedBVIDs(model).contains(Self.nextPageBVID))
        #expect(model.dislikedRecommendations.count == 2)

        model.refreshRecommendation()
        await model.waitForCurrentTask()
        #expect(BrowseFeed.recommendation.loadedBVIDs(model).contains(Self.refreshedBVID))
        #expect(model.dislikedRecommendations == [kept.target.bvid: kept])
        #expect(model.unmarkRecommendationDisliked(dropped) == nil)
    }

    @Test
    func revertUndoesOnlyItsOwnStepInTheSameWorkset() async throws {
        let model = await loadedModel()
        let feedback = try Self.feedback(reason: .content)

        let mark = try #require(model.markRecommendationDisliked(feedback))
        model.revertRecommendationDislike(mark)
        #expect(model.dislikedRecommendations.isEmpty)

        _ = model.markRecommendationDisliked(feedback)
        let undo = try #require(model.unmarkRecommendationDisliked(feedback))
        model.refreshRecommendation()
        await model.waitForCurrentTask()
        model.revertRecommendationDislike(undo)
        #expect(model.dislikedRecommendations == [feedback.target.bvid: feedback])

        // 换了账户后的新推荐恰好有同一视频：不能标上旧账户的反馈。
        let staleUndo = try #require(model.unmarkRecommendationDisliked(feedback))
        model.synchronizeAuthenticationSession(generation: 1)
        await model.waitForCurrentTask()
        #expect(BrowseFeed.recommendation.loadedBVIDs(model).contains(feedback.target.bvid))
        model.revertRecommendationDislike(staleUndo)
        #expect(model.dislikedRecommendations.isEmpty)
    }

    @Test
    func dislikedCardStaysInPlaceUnavailableWithOnlyUndo() throws {
        let feedback = try Self.feedback(reason: .uploader)
        let video = Self.trackedVideo()
        let card = try #require(
            RecommendedNativeGridView.makePresentations(
                [video],
                disliked: [video.bvid: feedback]
            ).first
        )
        #expect(card.availability == .unavailable(badge: VideoCardMenuText.dislikedBadge))
        #expect(card.accessibilityLabel.hasPrefix(VideoCardMenuText.dislikedBadge))

        let writes = RecordedWrites()
        let menu = try #require(
            BrowseVideoCardMenu.menu(
                for: card,
                openURL: OpenURLAction { _ in .handled },
                writing: writes.writing,
                recommendation: .disliked(feedback)
            )
        )
        #expect(menu.items.map(\.title) == [VideoCardMenuText.undoNotInterested])
        menu.items[0].action()
        #expect(writes.cancelled == [feedback])
    }

    @Test
    func shownCardOffersBothReasonsAsASubmenu() throws {
        let video = Self.trackedVideo()
        let card = try #require(
            RecommendedNativeGridView.makePresentations([video], disliked: [:]).first
        )
        let writes = RecordedWrites()
        let menu = try #require(
            BrowseVideoCardMenu.menu(
                for: card,
                openURL: OpenURLAction { _ in .handled },
                writing: writes.writing,
                recommendation: .notDisliked(video)
            )
        )
        let notInterested = try #require(menu.items.first { !$0.submenu.isEmpty })
        #expect(notInterested.title == VideoCardMenuText.notInterested)
        #expect(
            notInterested.submenu.map(\.title)
                == [
                    VideoCardMenuText.notInterestedInContent,
                    VideoCardMenuText.notInterestedInUploader
                ]
        )
        #expect(
            menu.actionableItems.map(\.title).contains(
                VideoCardMenuText.submenuActionTitle(
                    parent: VideoCardMenuText.notInterested,
                    child: VideoCardMenuText.notInterestedInUploader
                )
            )
        )

        try #require(menu.enabledItem(id: "notInterestedInUploader")).action()
        #expect(writes.disliked == [try Self.feedback(reason: .uploader)])
    }

    @Test
    func noTrackingIDMeansNoFeedback() throws {
        let video = Self.trackedFixture.recommendedVideo
        let card = try #require(
            RecommendedNativeGridView.makePresentations([video], disliked: [:]).first
        )
        let writes = RecordedWrites()
        let menu = try #require(
            BrowseVideoCardMenu.menu(
                for: card,
                openURL: OpenURLAction { _ in .handled },
                writing: writes.writing,
                recommendation: .notDisliked(video)
            )
        )
        #expect(menu.items.allSatisfy { $0.submenu.isEmpty })
        #expect(!menu.items.map(\.title).contains(VideoCardMenuText.notInterested))
    }

    /// 首次加载给出固定条目与 `secondBVID`，此后每次刷新（第一批的再次请求）给出固定条目与 `refreshedBVID`；下一批
    /// 只有 `nextPageBVID`。
    private func loadedModel() async -> BrowseViewModel {
        let first = RecommendationContinuation(freshIndex: 1)
        let next = RecommendationContinuation(freshIndex: 2)
        let fixed = Self.trackedVideo()
        let second = Self.trackedVideo(Self.secondBVID)
        let refreshed = Self.trackedVideo(Self.refreshedBVID)
        let nextPage = Self.trackedVideo(Self.nextPageBVID)
        let model = BrowseViewModel(
            useCase: FeedUseCase(
                repository: FeedRepositoryStub(recommendations: { continuation, attempt in
                    RecommendationPage(
                        videos: continuation == nil
                            ? [fixed, attempt == 1 ? second : refreshed]
                            : [nextPage],
                        continuation: continuation ?? first,
                        nextContinuation: continuation == nil ? next : nil
                    )
                })
            )
        )
        await model.activate(.recommendation)
        return model
    }

    private static func trackedVideo(_ bvid: String = trackedFixture.bvid) -> RecommendedVideo {
        let video = trackedFixture.recommendedVideo
        return RecommendedVideo(
            bvid: bvid,
            title: video.title,
            coverURL: nil,
            owner: video.owner,
            statistics: video.statistics,
            durationSeconds: video.durationSeconds,
            publishedAt: video.publishedAt,
            recommendationReason: nil,
            trackID: "track"
        )
    }

    private static func feedback(
        bvid: String = trackedFixture.bvid,
        reason: RecommendationDislikeReason
    ) throws -> RecommendationFeedback {
        let target = try #require(VideoWriteTarget(bvid: bvid))
        return try #require(
            RecommendationFeedback(
                target: target,
                uploaderID: trackedFixture.owner.id,
                trackID: "track",
                reason: reason
            )
        )
    }
}
