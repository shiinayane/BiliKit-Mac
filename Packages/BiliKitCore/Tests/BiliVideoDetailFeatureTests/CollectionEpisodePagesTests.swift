import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 合集选集的分 P 按需读取，每次选择只交出一个经过校验的跳转目标。
///
/// 已知分 P 不发请求，同一 BVID 只请求一次；失败只影响该选集、通知一次选择者并可重试，重试成功仍按原选择跳转；
/// 被取代或 reset 后的迟到结果被丢弃，被取消的请求不触发重新校验；分 P 缓存有上界。跨 BVID 带显式 CID 加载时
/// 只请求这个 CID，失败重试后仍保留它；显式选中的重复 BVID 那一集在上下文更新后仍被选中。
@Suite(.timeLimit(.minutes(1)))
struct CollectionEpisodePagesTests {
    @Test
    @MainActor
    func crossBVIDExplicitCIDLoadsOnlyTheAtomicTarget() async {
        let fixtures = CollectionFixtures()
        let repository = VideoRepositoryStub(collection: fixtures)
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )

        model.loadVideo(
            fixtures.episodeBVID,
            preferredCID: fixtures.episodePages[1].cid
        )
        #expect(model.requestedSelectionBVID == fixtures.episodeBVID)
        #expect(model.requestedPreferredCID == fixtures.episodePages[1].cid)
        #expect(model.presentedPlaybackIdentity == nil)
        await waitUntilSettled(model)

        #expect(model.presentedPlaybackIdentity?.bvid == fixtures.episodeBVID)
        #expect(model.presentedPlaybackIdentity?.cid == fixtures.episodePages[1].cid)
        #expect(await repository.playbackRequests.map(\.bvid) == [fixtures.episodeBVID])
        #expect(await repository.playbackRequests.map(\.cid) == [fixtures.episodePages[1].cid])
    }

    @Test
    @MainActor
    func crossBVIDFailureRetryRetainsExplicitCID() async {
        let fixtures = CollectionFixtures()
        let repository = VideoRepositoryStub(
            collection: fixtures,
            failsFirstEpisodeDetail: true
        )
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )

        model.loadVideo(
            fixtures.episodeBVID,
            preferredCID: fixtures.episodePages[1].cid
        )
        await waitUntilSettled(model)
        #expect(model.requestedPreferredCID == fixtures.episodePages[1].cid)
        #expect(model.presentedPlaybackIdentity == nil)

        model.retry()
        await waitUntilSettled(model)

        #expect(model.presentedPlaybackIdentity?.cid == fixtures.episodePages[1].cid)
        #expect(await repository.playbackRequests.map(\.bvid) == [fixtures.episodeBVID])
        #expect(await repository.playbackRequests.map(\.cid) == [fixtures.episodePages[1].cid])
    }

    @Test
    @MainActor
    func unknownEpisodePagesStayPendingThenResolveOneValidatedIntent() async throws {
        let fixtures = CollectionFixtures()
        let gate = TestGate()
        let repository = VideoRepositoryStub(collection: fixtures, gate: gate)
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )
        model.loadVideo(fixtures.rootBVID)
        await waitUntilSettled(model)
        var resolved: [(String, Int64?)] = []

        model.selectCollectionEpisode(fixtures.lazyEpisode) {
            resolved.append(($0, $1))
        }
        try await gate.waitForEntries()

        #expect(model.selectedCollectionEpisode == fixtures.lazyEpisode.id)
        #expect(model.collectionEpisodePageStates[fixtures.lazyEpisode.id] == .loading)
        #expect(resolved.isEmpty)

        await gate.open()
        await waitForObservedState {
            model.collectionEpisodePageStates[fixtures.lazyEpisode.id]
                == .loaded(bvid: fixtures.episodeBVID)
        }

        #expect(resolved.count == 1)
        #expect(resolved.first?.0 == fixtures.episodeBVID)
        #expect(resolved.first?.1 == fixtures.episodePages.first?.cid)
    }

    @Test
    @MainActor
    func explicitDuplicateBVIDOccurrenceSurvivesContextReconciliation() async {
        let fixtures = CollectionFixtures()
        let repository = VideoRepositoryStub(collection: fixtures)
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )

        model.loadVideo(fixtures.rootBVID)
        await waitUntilSettled(model)
        model.selectCollectionEpisode(fixtures.rootSummaryEpisode) { _, _ in }
        #expect(model.selectedCollectionEpisode == fixtures.rootSummaryEpisode.id)

        model.loadVideo(
            fixtures.rootBVID,
            preferredCID: fixtures.rootPages[1].cid
        )
        await waitUntilSettled(model)

        #expect(model.selectedCollectionEpisode == fixtures.rootSummaryEpisode.id)
    }

    @Test
    @MainActor
    func duplicateBVIDEpisodeSelectionsShareOneDetailRequest() async throws {
        let fixtures = CollectionFixtures()
        let gate = TestGate()
        let repository = VideoRepositoryStub(collection: fixtures, gate: gate)
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )

        model.loadVideo(fixtures.rootBVID)
        await waitUntilSettled(model)
        model.selectCollectionEpisode(fixtures.lazyEpisode) { _, _ in }
        model.selectCollectionEpisode(fixtures.duplicateLazyEpisode) { _, _ in }
        try await gate.waitForEntries()
        await gate.open()
        await waitForObservedState {
            model.collectionEpisodePageStates[fixtures.duplicateLazyEpisode.id]
                == .loaded(bvid: fixtures.episodeBVID)
        }

        #expect(await repository.episodeDetailRequestCount(in: fixtures) == 1)
        #expect(
            model.collectionEpisodePageStates[fixtures.lazyEpisode.id] == .idle
        )
        #expect(
            model.collectionEpisodePageStates[fixtures.duplicateLazyEpisode.id]
                == .loaded(bvid: fixtures.episodeBVID)
        )
    }

    @Test
    @MainActor
    func cancelledEpisodeFailureDoesNotRevalidateAuthentication() async throws {
        let fixtures = CollectionFixtures()
        let gate = TestGate()
        let passedGate = TestEventCounter()
        let repository = VideoRepositoryStub(
            collection: fixtures,
            gate: gate,
            passedGate: passedGate,
            episodeFailureAfterGate: .authenticationInvalid
        )
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )

        model.loadVideo(fixtures.rootBVID)
        await waitUntilSettled(model)
        model.selectCollectionEpisode(fixtures.lazyEpisode) { _, _ in }
        try await gate.waitForEntries()
        model.selectCollectionEpisode(fixtures.embeddedEpisode) { _, _ in }
        // 改选分集必须先取消挂起的旧请求；放行后旧请求带着认证失效离开替身，才断言没有触发重新校验。
        try await gate.waitForCancellations()
        await gate.open()
        try await passedGate.wait(until: 1)

        #expect(model.authenticationRevalidationGeneration == 0)
        #expect(model.collectionEpisodePageStates[fixtures.lazyEpisode.id] == .idle)
    }

    @Test
    @MainActor
    func episodeFailureIsLocalAndRetryCanRecover() async throws {
        let fixtures = CollectionFixtures()
        let repository = VideoRepositoryStub(
            collection: fixtures,
            failsFirstEpisodeDetail: true
        )
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )

        model.loadVideo(fixtures.rootBVID)
        await waitUntilSettled(model)
        var failures = 0
        var resolved: [String] = []
        model.selectCollectionEpisode(
            fixtures.lazyEpisode,
            onResolved: { bvid, _ in resolved.append(bvid) },
            onFailed: { failures += 1 }
        )
        await waitForObservedState {
            model.collectionEpisodePageStates[fixtures.lazyEpisode.id]
                == .failed(.transportFailure)
        }
        #expect(model.presentedContext?.detail.bvid == fixtures.rootBVID)
        #expect(failures == 1)

        model.retryCollectionEpisodePages(fixtures.lazyEpisode)
        await waitForObservedState {
            model.collectionEpisodePageStates[fixtures.lazyEpisode.id]
                == .loaded(bvid: fixtures.episodeBVID)
        }
        #expect(await repository.episodeDetailRequestCount(in: fixtures) == 2)
        #expect(failures == 1)
        #expect(resolved == [fixtures.episodeBVID])
    }

    @Test
    @MainActor
    func resetRejectsLateCollectionEpisodePages() async throws {
        let fixtures = CollectionFixtures()
        let gate = TestGate()
        let repository = VideoRepositoryStub(collection: fixtures, gate: gate)
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )

        model.loadVideo(fixtures.rootBVID)
        await waitUntilSettled(model)
        model.selectCollectionEpisode(fixtures.lazyEpisode) { _, _ in }
        try await gate.waitForEntries()

        model.reset()
        await gate.open()

        #expect(model.selectedCollectionEpisode == nil)
        #expect(model.collectionEpisodePageStates.isEmpty)
        #expect(model.presentedContext == nil)
    }

    @Test
    @MainActor
    func differentBVIDSelectionCancelsOldRequestAndRejectsItsLateResult() async throws {
        let fixtures = CollectionFixtures()
        let gate = TestGate()
        let repository = VideoRepositoryStub(collection: fixtures, gate: gate)
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )

        model.loadVideo(fixtures.rootBVID)
        await waitUntilSettled(model)
        model.selectCollectionEpisode(fixtures.lazyEpisode) { _, _ in }
        try await gate.waitForEntries(1)
        model.selectCollectionEpisode(fixtures.thirdLazyEpisode) { _, _ in }

        try await gate.waitForEntries(2)
        #expect(await repository.episodeDetailRequestCount(in: fixtures) == 2)
        #expect(model.collectionEpisodePageStates[fixtures.lazyEpisode.id] == .idle)
        #expect(model.collectionEpisodePageStates[fixtures.thirdLazyEpisode.id] == .loading)

        await gate.open()
        await waitForObservedState {
            model.collectionEpisodePageStates[fixtures.thirdLazyEpisode.id]
                == .loaded(bvid: fixtures.thirdBVID)
        }

        #expect(await repository.episodeDetailRequestCount(in: fixtures) == 2)
        #expect(
            model.collectionEpisodePageStates[fixtures.lazyEpisode.id] == .idle
        )
    }

    @Test
    @MainActor
    func knownEpisodePagesResolveSelectionsWithoutRemoteDetail() async {
        let fixtures = CollectionFixtures()
        let repository = VideoRepositoryStub(collection: fixtures)
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )

        model.loadVideo(fixtures.rootBVID)
        await waitUntilSettled(model)
        var embeddedSelection: String?
        model.selectCollectionEpisode(fixtures.embeddedEpisode) { bvid, _ in
            embeddedSelection = bvid
        }
        #expect(embeddedSelection == fixtures.rootBVID)
        #expect(
            model.collectionEpisodePages(for: fixtures.embeddedEpisode.id)
                == fixtures.rootPages
        )
        model.selectCollectionEpisode(fixtures.rootSummaryEpisode) { _, _ in }
        model.selectCollectionEpisode(fixtures.embeddedRemoteEpisode) { _, _ in }
        model.selectCollectionEpisode(fixtures.lazyEpisode) { _, _ in }

        #expect(await repository.episodeDetailRequestCount(in: fixtures) == 0)
        #expect(
            model.collectionEpisodePages(for: fixtures.lazyEpisode.id)
                == fixtures.episodePages
        )
    }

    @Test
    @MainActor
    func episodePageCacheEvictsAndReleasesTheThirteenthBVID() async {
        let fixtures = BoundedCollectionCacheFixtures()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(
                    detail: { _, _ in fixtures.detail },
                    pages: { _, _ in fixtures.detail.pages },
                    playback: { _, _ in emptyPlayback() }
                )
            ),
            playback: PlayerStub()
        )

        model.loadVideo(fixtures.rootBVID)
        await waitUntilSettled(model)
        for episode in fixtures.episodes {
            model.selectCollectionEpisode(episode) { _, _ in }
        }

        let first = fixtures.episodes[0]
        let last = fixtures.episodes[12]
        #expect(model.selectedCollectionEpisode == last.id)
        #expect(model.collectionEpisodePageStates[first.id] == .idle)
        #expect(model.collectionEpisodePages(for: first.id) == nil)
        #expect(model.collectionEpisodePageStates[last.id] == .loaded(bvid: last.bvid!))
        #expect(model.collectionEpisodePages(for: last.id) == last.knownPages)
    }
}

private struct BoundedCollectionCacheFixtures: Sendable {
    let rootBVID = "BV1CacheRoot"

    var episodes: [VideoCollectionEpisode] {
        (1...13).map { value in
            let bvid = String(format: "BV1Cache%04d", value)
            let page = VideoPage(
                cid: Int64(930_000 + value),
                index: 1,
                title: "P1",
                durationSeconds: 10
            )
            return VideoCollectionEpisode(
                id: VideoCollectionEpisodeIdentity(
                    seasonID: 801,
                    sectionID: 802,
                    episodeID: Int64(8_100 + value)
                ),
                ordinal: value - 1,
                aid: Int64(9_100 + value),
                bvid: bvid,
                title: "缓存视频 \(value)",
                coverURL: nil,
                durationSeconds: 10,
                defaultCID: page.cid,
                knownPages: [page]
            )
        }
    }

    var detail: VideoDetail {
        let rootPage = VideoPage(
            cid: 939_999,
            index: 1,
            title: "当前 P1",
            durationSeconds: 10
        )
        return makeVideoDetail(
            bvid: rootBVID,
            title: "缓存边界",
            summary: "脱敏详情",
            owner: VideoOwner(id: 10_001, name: "测试 UP 主"),
            statistics: VideoStatistics(viewCount: 1, danmakuCount: 1, likeCount: 1),
            durationSeconds: 10,
            pages: [rootPage],
            collection: VideoCollection(
                id: 801,
                title: "缓存合集",
                reportedEpisodeCount: 13,
                sections: [
                    VideoCollectionSection(
                        id: VideoCollectionSectionIdentity(
                            seasonID: 801,
                            sectionID: 802
                        ),
                        ordinal: 0,
                        title: "分部",
                        episodes: episodes
                    )
                ]
            )
        )
    }
}

private struct CollectionFixtures: Sendable {
    let rootBVID = "BV1FixtureA1"
    let episodeBVID = "BV1FixtureB2"
    let thirdBVID = "BV1FixtureC3"
    let rootPages = [
        VideoPage(cid: 900_001, index: 1, title: "当前 P1", durationSeconds: 120),
        VideoPage(cid: 900_002, index: 2, title: "当前 P2", durationSeconds: 180)
    ]
    let episodePages = [
        VideoPage(cid: 910_001, index: 1, title: "下一 P1", durationSeconds: 90),
        VideoPage(cid: 910_002, index: 2, title: "下一 P2", durationSeconds: 110)
    ]
    let thirdPages = [
        VideoPage(cid: 920_001, index: 1, title: "第三 P1", durationSeconds: 80)
    ]

    var embeddedEpisode: VideoCollectionEpisode {
        episode(
            episodeID: 701,
            ordinal: 0,
            bvid: rootBVID,
            pages: rootPages
        )
    }

    var lazyEpisode: VideoCollectionEpisode {
        episode(
            episodeID: 702,
            ordinal: 1,
            bvid: episodeBVID,
            pages: nil
        )
    }

    var duplicateLazyEpisode: VideoCollectionEpisode {
        episode(
            episodeID: 703,
            ordinal: 2,
            bvid: episodeBVID,
            pages: nil
        )
    }

    var thirdLazyEpisode: VideoCollectionEpisode {
        episode(episodeID: 704, ordinal: 3, bvid: thirdBVID, pages: nil)
    }

    var rootSummaryEpisode: VideoCollectionEpisode {
        episode(episodeID: 705, ordinal: 4, bvid: rootBVID, pages: nil)
    }

    var embeddedRemoteEpisode: VideoCollectionEpisode {
        episode(episodeID: 706, ordinal: 5, bvid: episodeBVID, pages: episodePages)
    }

    var rootDetail: VideoDetail {
        detail(
            bvid: rootBVID,
            pages: rootPages,
            collection: VideoCollection(
                id: 501,
                title: "测试合集",
                reportedEpisodeCount: 6,
                sections: [
                    VideoCollectionSection(
                        id: VideoCollectionSectionIdentity(
                            seasonID: 501,
                            sectionID: 601
                        ),
                        ordinal: 0,
                        title: "第一章",
                        episodes: [
                            embeddedEpisode,
                            lazyEpisode,
                            duplicateLazyEpisode,
                            thirdLazyEpisode,
                            rootSummaryEpisode,
                            embeddedRemoteEpisode
                        ]
                    )
                ]
            )
        )
    }

    var episodeDetail: VideoDetail {
        detail(bvid: episodeBVID, pages: episodePages, collection: nil)
    }

    var thirdDetail: VideoDetail {
        detail(bvid: thirdBVID, pages: thirdPages, collection: nil)
    }

    func detail(for bvid: String) -> VideoDetail {
        switch bvid {
        case rootBVID: rootDetail
        case episodeBVID: episodeDetail
        default: thirdDetail
        }
    }

    private func episode(
        episodeID: Int64,
        ordinal: Int,
        bvid: String,
        pages: [VideoPage]?
    ) -> VideoCollectionEpisode {
        VideoCollectionEpisode(
            id: VideoCollectionEpisodeIdentity(
                seasonID: 501,
                sectionID: 601,
                episodeID: episodeID
            ),
            ordinal: ordinal,
            aid: episodeID + 6_000,
            bvid: bvid,
            title: "合集视频 \(ordinal + 1)",
            coverURL: nil,
            durationSeconds: pages?.reduce(0) { $0 + $1.durationSeconds },
            defaultCID: pages?.first?.cid,
            knownPages: pages
        )
    }

    private func detail(
        bvid: String,
        pages: [VideoPage],
        collection: VideoCollection?
    ) -> VideoDetail {
        makeVideoDetail(
            bvid: bvid,
            title: "详情 \(bvid)",
            summary: "脱敏详情",
            owner: VideoOwner(id: 10_001, name: "测试 UP 主"),
            statistics: VideoStatistics(
                viewCount: 10,
                danmakuCount: 2,
                likeCount: 3
            ),
            durationSeconds: pages.reduce(0) { $0 + $1.durationSeconds },
            pages: pages,
            collection: collection
        )
    }
}

/// 本文件两套合集 fixture 共用的播放地址：空清单，不带请求头。
private func emptyPlayback() -> VideoPlayback {
    VideoPlayback(
        media: .dash(
            PlaybackManifest(
                videoRepresentations: [],
                audioTracks: []
            )
        ),
        mediaHeaders: [:]
    )
}

extension VideoRepositoryStub {
    /// 合集 fixture：根视频详情立即返回，其余 BVID 的详情先经过 `gate`（若有）。
    ///
    /// `failsFirstEpisodeDetail` 让每个 BVID 的首次详情请求失败，`episodeFailureAfterGate` 让放行后的请求失败；
    /// `passedGate` 在请求通过闸门、即将返回或抛错时记一次，测试据此确认放行的请求已离开替身。
    fileprivate init(
        collection fixtures: CollectionFixtures,
        gate: TestGate? = nil,
        passedGate: TestEventCounter? = nil,
        failsFirstEpisodeDetail: Bool = false,
        episodeFailureAfterGate: ContentApplicationError? = nil
    ) {
        self.init(
            detail: { bvid, attempt in
                guard bvid != fixtures.rootBVID else { return fixtures.rootDetail }
                if failsFirstEpisodeDetail, attempt == 1 {
                    throw ContentApplicationError.transportFailure
                }
                await gate?.pass()
                await passedGate?.signal()
                if let episodeFailureAfterGate { throw episodeFailureAfterGate }
                return fixtures.detail(for: bvid)
            },
            pages: { bvid, _ in fixtures.detail(for: bvid).pages },
            playback: { _, _ in emptyPlayback() }
        )
    }

    /// 合集根视频以外的详情请求，即按需加载分集分 P 的远端请求。
    fileprivate func episodeDetailRequestCount(in fixtures: CollectionFixtures) -> Int {
        detailRequests.filter { $0 != fixtures.rootBVID }.count
    }
}
