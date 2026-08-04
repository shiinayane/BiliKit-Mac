//
//  BiliKitMacTests.swift
//  BiliKitMacTests
//
//  Created by shiinayane on 2026/07/21.
//

import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliBrowseFeature

@Suite(.timeLimit(.minutes(1)))
struct GuestBrowseAndVideoViewModelTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func newerPopularRequestPreventsOldSearchFromOverwritingFeed() async throws {
        let fixture = GuestFixtures()
        let repository = FeedSwitchingRepositoryStub(fixtures: fixture)
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(
                repository: repository
            )
        )

        model.search("旧搜索")
        try await repository.waitForSearchStart()
        let supersededTask = try #require(model.taskSnapshotForTesting())
        model.refreshPopular()
        await model.waitForCurrentTask()
        await repository.releaseSearch()
        await supersededTask.value

        #expect(
            model.state
                == .loaded(
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
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(
                repository: RetryingSearchRepositoryStub(fixtures: fixture)
            )
        )

        model.search("macOS", page: 2)
        await model.waitForCurrentTask()
        #expect(
            model.state
                == .failed(
                    request: .search(query: "macOS", page: 2),
                    error: .requestRestricted
                )
        )

        model.retry(.search(query: "macOS", page: 2))
        await model.waitForCurrentTask()
        #expect(
            model.state
                == .loaded(
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
    func tabRoundTripReusesPopularAndSearchWorksetsWithoutNewRequests() async {
        let fixture = GuestFixtures()
        let repository = WorksetRepositoryStub(fixtures: fixture)
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )
        let searchRequest = GuestFeedRequest.search(query: "macOS", page: 1)

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()

        model.activateSearch("macOS")
        await model.waitForCurrentTask()
        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()

        #expect(await repository.popularCallCount == 1)
        #expect(await repository.searchCallCount == 1)
        #expect(
            model.presentation(for: searchRequest).state
                == .loaded(
                    .search(
                        query: "macOS",
                        page: SearchPage(
                            videos: [fixture.searchVideo],
                            pageNumber: 1,
                            pageSize: 20,
                            totalResults: 1,
                            totalPages: 1
                        )
                    )
                )
        )
        #expect(
            model.state
                == .loaded(
                    .popular(
                        PopularPage(
                            videos: [fixture.popularVideo],
                            pageNumber: 1,
                            pageSize: 50
                        )
                    )
                )
        )
    }

    @Test
    @MainActor
    func failedRefreshKeepsMatchingLoadedContentVisible() async {
        let fixture = GuestFixtures()
        let repository = WorksetRepositoryStub(fixtures: fixture)
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        let loadedState = model.state
        await repository.failNextPopularRequest()

        model.refreshPopular(pageSize: 50)
        #expect(model.state == loadedState)
        #expect(model.isRefreshing)
        await model.waitForCurrentTask()

        #expect(model.state == loadedState)
        #expect(!model.isRefreshing)
        #expect(model.refreshError == .requestRestricted)
        #expect(await repository.popularCallCount == 2)
    }

    @Test
    @MainActor
    func resetClearsWorksetsAndRequiresANewLoad() async {
        let fixture = GuestFixtures()
        let repository = WorksetRepositoryStub(fixtures: fixture)
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )
        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        model.reset()

        #expect(
            model.presentation(
                for: .popular(page: 1, pageSize: 50)
            ).state == .idle
        )
        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        #expect(await repository.popularCallCount == 2)
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

        model.loadVideo(fixture.detail.bvid)
        await model.waitForCurrentTask()

        let context = GuestVideoContext(
            detail: fixture.detail,
            pages: [fixture.page],
            selectedPage: fixture.page,
            playback: fixture.playback
        )
        #expect(model.state == .ready(context))
        #expect(player.loadedPlaybacks == [fixture.playback])
        #expect(
            player.loadedIdentities == [
                PlaybackItemIdentity(
                    bvid: fixture.detail.bvid,
                    cid: fixture.page.cid
                )
            ]
        )
    }

    @Test
    @MainActor
    func resettingVideoLoadClearsDetailAndStopsPlayer() async {
        let fixture = GuestFixtures()
        let player = RecordingPlayerEngine()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: GuestRepositoryStub(fixtures: fixture)
            ),
            playback: player
        )

        model.loadVideo(fixture.bvid)
        await model.waitForCurrentTask()
        model.reset()

        #expect(model.state == .idle)
        #expect(player.stopCallCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func newerVideoLoadPreventsOldVideoFromLoadingPlayer() async throws {
        let slow = GuestFixtures(bvid: "BV1SlowFixture", title: "旧视频")
        let fast = GuestFixtures(bvid: "BV1FastFixture", title: "新视频")
        let player = RecordingPlayerEngine()
        let repository = SwitchingGuestRepositoryStub(slow: slow, fast: fast)
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: repository
            ),
            playback: player
        )

        model.loadVideo(slow.detail.bvid)
        try await repository.waitForSlowRequestCount(2)
        let supersededTask = try #require(model.taskSnapshotForTesting())
        model.loadVideo(fast.detail.bvid)
        await model.waitForCurrentTask()
        await repository.releaseSlowRequests()
        await supersededTask.value

        guard case .ready(let context) = model.state else {
            Issue.record("最新视频未进入就绪状态")
            return
        }
        #expect(context.detail.bvid == fast.detail.bvid)
        #expect(player.loadedPlaybacks.count == 1)
        #expect(player.stopCallCount == 1)
        #expect(
            player.loadedPlaybacks.first?.mediaHeaders["Referer"]?.contains(
                fast.detail.bvid
            ) == true
        )
    }
}

private actor WorksetRepositoryStub: GuestContentRepository {
    let fixtures: GuestFixtures
    private(set) var popularCallCount = 0
    private(set) var searchCallCount = 0
    private var shouldFailNextPopular = false

    init(fixtures: GuestFixtures) {
        self.fixtures = fixtures
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        popularCallCount += 1
        if shouldFailNextPopular {
            shouldFailNextPopular = false
            throw GuestApplicationError.requestRestricted
        }
        return PopularPage(
            videos: [fixtures.popularVideo],
            pageNumber: page,
            pageSize: pageSize
        )
    }

    func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        searchCallCount += 1
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
        cid: Int64
    ) async throws -> VideoPlayback {
        fixtures.playback
    }

    func failNextPopularRequest() {
        shouldFailNextPopular = true
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
        cid: Int64
    ) async throws -> VideoPlayback {
        fixtures.playback
    }
}

private actor FeedSwitchingRepositoryStub: GuestContentRepository {
    let fixtures: GuestFixtures
    private var searchReleased = false
    private let searchEvents = TestEventCounter()
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

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
        await searchEvents.signal()
        await withCheckedContinuation { continuation in
            if searchReleased {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
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
        cid: Int64
    ) async throws -> VideoPlayback {
        fixtures.playback
    }

    func waitForSearchStart() async throws {
        do {
            try await searchEvents.wait(until: 1)
        } catch {
            releaseSearch()
            throw error
        }
    }

    func releaseSearch() {
        searchReleased = true
        resume(&releaseWaiters)
    }

    private func resume(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
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
        cid: Int64
    ) async throws -> VideoPlayback {
        fixtures.playback
    }
}

private actor SwitchingGuestRepositoryStub: GuestContentRepository {
    let slow: GuestFixtures
    let fast: GuestFixtures
    private var slowRequestsReleased = false
    private let slowRequestEvents = TestEventCounter()
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

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
        cid: Int64
    ) async throws -> VideoPlayback {
        fixture(for: bvid).playback
    }

    private func delayIfSlow(_ bvid: String) async throws {
        guard bvid == slow.bvid else { return }
        await slowRequestEvents.signal()
        await withCheckedContinuation { continuation in
            if slowRequestsReleased {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
    }

    private func fixture(for bvid: String) -> GuestFixtures {
        bvid == slow.bvid ? slow : fast
    }

    func waitForSlowRequestCount(_ expectedCount: Int) async throws {
        do {
            try await slowRequestEvents.wait(until: expectedCount)
        } catch {
            releaseSlowRequests()
            throw error
        }
    }

    func releaseSlowRequests() {
        slowRequestsReleased = true
        let pending = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor TestEventCounter {
    private struct Waiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var count = 0
    private var waiters: [UUID: Waiter] = [:]

    func signal() {
        count += 1
        let ready = waiters.filter { count >= $0.value.expectedCount }
        for (id, waiter) in ready where waiters.removeValue(forKey: id) != nil {
            waiter.continuation.resume()
        }
    }

    func wait(until expectedCount: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if count >= expectedCount {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = Waiter(
                        expectedCount: expectedCount,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id)
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }
}

@MainActor
private final class RecordingPlayerEngine: PlaybackControlling {
    private(set) var loadedPlaybacks: [VideoPlayback] = []
    private(set) var loadedIdentities: [PlaybackItemIdentity] = []
    private(set) var pauseCallCount = 0
    private(set) var stopCallCount = 0

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity
    ) async throws {
        loadedPlaybacks.append(playback)
        loadedIdentities.append(identity)
    }

    func pause() {
        pauseCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }
}
