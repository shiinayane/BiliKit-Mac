//
//  BiliKitMacTests.swift
//  BiliKitMacTests
//
//  Created by shiinayane on 2026/07/21.
//

import BiliApplication
import BiliBrowseFeature
import BiliModels
import Foundation
import Testing

struct GuestViewModelTests {
    @Test
    @MainActor
    func modelLoadsPopularPage() async {
        let fixture = GuestFixtures()
        let model = GuestFeedViewModel(
            useCase: GuestFeedUseCase(
                repository: GuestRepositoryStub(fixtures: fixture)
            )
        )

        model.loadPopular(page: 2, pageSize: 10)
        await model.waitForCurrentTask()

        #expect(
            model.state == .loaded(
                .popular(
                    PopularPage(
                        videos: [fixture.popularVideo],
                        pageNumber: 2,
                        pageSize: 10
                    )
                )
            )
        )
    }

    @Test
    @MainActor
    func modelSearchesVideosWithNormalizedQuery() async {
        let fixture = GuestFixtures()
        let model = GuestFeedViewModel(
            useCase: GuestFeedUseCase(
                repository: GuestRepositoryStub(fixtures: fixture)
            )
        )

        model.search("  macOS  ", page: 2)
        await model.waitForCurrentTask()

        #expect(
            model.state == .loaded(
                .search(
                    query: "macOS",
                    page: SearchPage(
                        videos: [fixture.searchVideo],
                        pageNumber: 2,
                        pageSize: 20,
                        totalResults: 1,
                        totalPages: 1
                    )
                )
            )
        )
    }

    @Test
    @MainActor
    func newerPopularRequestPreventsOldSearchFromOverwritingFeed() async throws {
        let fixture = GuestFixtures()
        let model = GuestFeedViewModel(
            useCase: GuestFeedUseCase(
                repository: FeedSwitchingRepositoryStub(fixtures: fixture)
            )
        )

        model.search("旧搜索")
        try await Task.sleep(for: .milliseconds(10))
        model.loadPopular()
        await model.waitForCurrentTask()
        try await Task.sleep(for: .milliseconds(30))

        #expect(
            model.state == .loaded(
                .popular(
                    PopularPage(
                        videos: [fixture.popularVideo],
                        pageNumber: 1,
                        pageSize: 20
                    )
                )
            )
        )
    }

    @Test
    @MainActor
    func failedSearchRetriesItsOriginalRequest() async {
        let fixture = GuestFixtures()
        let model = GuestFeedViewModel(
            useCase: GuestFeedUseCase(
                repository: RetryingSearchRepositoryStub(fixtures: fixture)
            )
        )

        model.search("macOS", page: 2)
        await model.waitForCurrentTask()
        #expect(
            model.state == .failed(
                request: .search(query: "macOS", page: 2),
                error: .requestRestricted
            )
        )

        model.retry()
        await model.waitForCurrentTask()
        #expect(
            model.state == .loaded(
                .search(
                    query: "macOS",
                    page: SearchPage(
                        videos: [fixture.searchVideo],
                        pageNumber: 2,
                        pageSize: 20,
                        totalResults: 1,
                        totalPages: 1
                    )
                )
            )
        )
    }

    @Test
    @MainActor
    func modelResolvesGuestFlowAndLoadsPlayerRequest() async {
        let fixture = GuestFixtures()
        let player = RecordingPlayerEngine()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: GuestRepositoryStub(fixtures: fixture)
            ),
            playback: player
        )

        model.selectVideo(fixture.detail.bvid)
        await model.waitForCurrentTask()

        let context = GuestVideoContext(
            detail: fixture.detail,
            pages: [fixture.page],
            selectedPage: fixture.page,
            playback: fixture.playback
        )
        #expect(model.state == .ready(context))
        #expect(player.loadedPlaybacks == [fixture.playback])
    }

    @Test
    @MainActor
    func resettingSelectionClearsDetailAndPausesPlayer() async {
        let fixture = GuestFixtures()
        let player = RecordingPlayerEngine()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: GuestRepositoryStub(fixtures: fixture)
            ),
            playback: player
        )

        model.selectVideo(fixture.bvid)
        await model.waitForCurrentTask()
        model.reset()

        #expect(model.state == .idle)
        #expect(player.pauseCallCount == 1)
    }

    @Test
    @MainActor
    func newerSelectionPreventsOldVideoFromLoadingPlayer() async throws {
        let slow = GuestFixtures(bvid: "BV1SlowFixture", title: "旧视频")
        let fast = GuestFixtures(bvid: "BV1FastFixture", title: "新视频")
        let player = RecordingPlayerEngine()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: SwitchingGuestRepositoryStub(slow: slow, fast: fast)
            ),
            playback: player
        )

        model.selectVideo(slow.detail.bvid)
        try await Task.sleep(for: .milliseconds(10))
        model.selectVideo(fast.detail.bvid)
        await model.waitForCurrentTask()
        try await Task.sleep(for: .milliseconds(120))

        guard case let .ready(context) = model.state else {
            Issue.record("最新视频未进入就绪状态")
            return
        }
        #expect(context.detail.bvid == fast.detail.bvid)
        #expect(player.loadedPlaybacks.count == 1)
        #expect(
            player.loadedPlaybacks.first?.mediaHeaders["Referer"]?.contains(
                fast.detail.bvid
            ) == true
        )
    }

}

private struct GuestFixtures: Sendable {
    let bvid: String
    let title: String
    let owner = VideoOwner(id: 10_001, name: "测试 UP 主")

    init(
        bvid: String = "BV1FixtureA1",
        title: String = "测试视频"
    ) {
        self.bvid = bvid
        self.title = title
    }

    var popularVideo: PopularVideo {
        PopularVideo(
            bvid: bvid,
            title: title,
            coverURL: nil,
            owner: owner,
            statistics: VideoStatistics(viewCount: 10, danmakuCount: 2, likeCount: 3),
            durationSeconds: 120,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    var detail: VideoDetail {
        VideoDetail(
            bvid: popularVideo.bvid,
            title: popularVideo.title,
            summary: "脱敏详情",
            coverURL: nil,
            owner: owner,
            statistics: popularVideo.statistics,
            durationSeconds: popularVideo.durationSeconds,
            publishedAt: popularVideo.publishedAt
        )
    }

    var searchVideo: SearchVideo {
        SearchVideo(
            bvid: bvid,
            title: title,
            coverURL: nil,
            owner: owner,
            statistics: popularVideo.statistics,
            durationSeconds: popularVideo.durationSeconds,
            publishedAt: popularVideo.publishedAt
        )
    }

    let page = VideoPage(
        cid: 900_001,
        index: 1,
        title: "P1",
        durationSeconds: 120
    )

    var playback: VideoPlayback {
        VideoPlayback(
            manifest: PlaybackManifest(
                videoRepresentations: [],
                audioRepresentations: []
            ),
            mediaHeaders: [
                "Referer": "https://www.bilibili.com/video/\(bvid)/",
                "User-Agent": "BiliKitMacTests",
            ]
        )
    }
}

private actor GuestRepositoryStub: GuestContentRepository {
    let fixtures: GuestFixtures

    init(fixtures: GuestFixtures) {
        self.fixtures = fixtures
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(
            videos: [fixtures.popularVideo],
            pageNumber: page,
            pageSize: pageSize
        )
    }

    func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        SearchPage(
            videos: [fixtures.searchVideo],
            pageNumber: page,
            pageSize: 20,
            totalResults: 1,
            totalPages: 1
        )
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        fixtures.detail
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        [fixtures.page]
    }

    func playback(
        for bvid: String,
        cid: Int64,
        quality: Int
    ) async throws -> VideoPlayback {
        fixtures.playback
    }
}

private actor FeedSwitchingRepositoryStub: GuestContentRepository {
    let fixtures: GuestFixtures

    init(fixtures: GuestFixtures) {
        self.fixtures = fixtures
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(
            videos: [fixtures.popularVideo],
            pageNumber: page,
            pageSize: pageSize
        )
    }

    func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        try? await Task.sleep(for: .milliseconds(100))
        return SearchPage(
            videos: [fixtures.searchVideo],
            pageNumber: page,
            pageSize: 20,
            totalResults: 1,
            totalPages: 1
        )
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        fixtures.detail
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        [fixtures.page]
    }

    func playback(
        for bvid: String,
        cid: Int64,
        quality: Int
    ) async throws -> VideoPlayback {
        fixtures.playback
    }
}

private actor RetryingSearchRepositoryStub: GuestContentRepository {
    let fixtures: GuestFixtures
    private var searchAttempts = 0

    init(fixtures: GuestFixtures) {
        self.fixtures = fixtures
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(
            videos: [fixtures.popularVideo],
            pageNumber: page,
            pageSize: pageSize
        )
    }

    func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        searchAttempts += 1
        if searchAttempts == 1 {
            throw GuestApplicationError.requestRestricted
        }
        return SearchPage(
            videos: [fixtures.searchVideo],
            pageNumber: page,
            pageSize: 20,
            totalResults: 1,
            totalPages: 1
        )
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        fixtures.detail
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        [fixtures.page]
    }

    func playback(
        for bvid: String,
        cid: Int64,
        quality: Int
    ) async throws -> VideoPlayback {
        fixtures.playback
    }
}

private actor SwitchingGuestRepositoryStub: GuestContentRepository {
    let slow: GuestFixtures
    let fast: GuestFixtures

    init(slow: GuestFixtures, fast: GuestFixtures) {
        self.slow = slow
        self.fast = fast
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(videos: [fast.popularVideo], pageNumber: page, pageSize: pageSize)
    }

    func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        SearchPage(
            videos: [],
            pageNumber: page,
            pageSize: 20,
            totalResults: 0,
            totalPages: 0
        )
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        try await delayIfSlow(bvid)
        return fixture(for: bvid).detail
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        try await delayIfSlow(bvid)
        return [fixture(for: bvid).page]
    }

    func playback(
        for bvid: String,
        cid: Int64,
        quality: Int
    ) async throws -> VideoPlayback {
        fixture(for: bvid).playback
    }

    private func delayIfSlow(_ bvid: String) async throws {
        if bvid == slow.bvid {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func fixture(for bvid: String) -> GuestFixtures {
        bvid == slow.bvid ? slow : fast
    }
}

@MainActor
private final class RecordingPlayerEngine: PlaybackControlling {
    private(set) var loadedPlaybacks: [VideoPlayback] = []
    private(set) var pauseCallCount = 0

    func load(_ playback: VideoPlayback) async throws {
        loadedPlaybacks.append(playback)
    }

    func pause() {
        pauseCallCount += 1
    }
}
