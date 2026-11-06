import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// UP 主空间视图模型的游标翻页、排序与重开规则。
///
/// 打开时读最新排序的第一批；滚到底加载下一批并累积，到底后不再请求；加载下一批失败保留已显示的投稿、由用户重试同一
/// 游标。提交搜索词换成空间内搜索结果、排序不生效，清空搜索或换 UP 主回到投稿列表的第一批。同一 UP 主再次打开保持已加载的内容并更新资料、失败时顺带重试，换 UP 主回到默认排序与第一批，换排序从第一批
/// 重来；关闭后的迟到结果不写回。只有 MID 的入口先打开、名片到达后补名字；凭据失效请求窗口复核，复核有了结果后停在
/// 失败页的第一批重载一次；会话在请求途中切换时关闭空间。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct UploaderSpaceViewModelTests {
    private let owner = VideoOwner(id: 10_001, name: "作者")
    private let anotherOwner = VideoOwner(id: 10_002, name: "另一位作者")

    @Test
    func openLoadsTheFirstBatchOfNewest() async {
        let repository = UploaderVideoRepositoryStub()
        let model = makeModel(repository)

        model.open(owner: owner)
        #expect(model.state == .loading)
        await waitForLoaded(model, count: 1)

        #expect(model.owner == owner)
        #expect(model.totalCount == 61)
        #expect(model.footer == .loadMore)
        #expect(await repository.calls == [.init(ownerID: 10_001, order: .newest, batch: 0)])
    }

    @Test
    func loadMoreAppendsUntilTheLastBatch() async {
        let repository = UploaderVideoRepositoryStub(batchCount: 2)
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, count: 1)

        model.loadMore()
        await waitForLoaded(model, count: 2)
        model.loadMore()

        #expect(model.footer == .none)
        #expect(model.loadMoreTailIdentity == nil)
        #expect(await repository.calls.map(\.batch) == [0, 1])
    }

    /// 下一批失败：已显示的投稿留着、不再自动加载；重试请求同一游标。
    @Test
    func loadMoreFailureKeepsVideosAndRetriesTheSameCursor() async {
        let repository = UploaderVideoRepositoryStub(failingBatches: [1: .transportFailure])
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, count: 1)

        model.loadMore()
        await waitForObservedState { model.footer == .failed(.transportFailure) }
        #expect(loadedCount(model) == 1)
        #expect(model.loadMoreTailIdentity == nil)
        await repository.setFailure(nil, batch: 1)
        model.loadMore()
        await waitForLoaded(model, count: 2)

        #expect(await repository.calls.map(\.batch) == [0, 1, 1])
    }

    @Test
    func reopeningTheSameOwnerKeepsLoadedVideos() async {
        let repository = UploaderVideoRepositoryStub()
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, count: 1)
        model.loadMore()
        await waitForLoaded(model, count: 2)

        model.open(owner: owner)

        #expect(loadedCount(model) == 2)
        #expect(await repository.calls.count == 2)
    }

    @Test
    func openingAnotherOwnerOrChangingOrderStartsOver() async {
        let repository = UploaderVideoRepositoryStub()
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, count: 1)
        model.setOrder(.mostPlayed)
        await waitForLoaded(model, count: 1)
        model.loadMore()
        await waitForLoaded(model, count: 2)

        model.open(owner: anotherOwner)
        await waitForLoaded(model, count: 1)

        #expect(model.order == .newest)
        #expect(
            await repository.calls == [
                .init(ownerID: 10_001, order: .newest, batch: 0),
                .init(ownerID: 10_001, order: .mostPlayed, batch: 0),
                .init(ownerID: 10_001, order: .mostPlayed, batch: 1),
                .init(ownerID: 10_002, order: .newest, batch: 0)
            ]
        )
    }

    @Test
    func emptySpaceLoadsAnEmptyListWithoutAFooter() async {
        let repository = UploaderVideoRepositoryStub(batchCount: 0)
        let model = makeModel(repository)

        model.open(owner: owner)
        await waitForObservedState { model.state != .loading }

        #expect(model.state == .loaded([]))
        #expect(model.footer == .none)
    }

    @Test
    func reopeningTheSameOwnerRefreshesProfileAndRetriesAFailure() async {
        let repository = UploaderVideoRepositoryStub(failingBatches: [0: .transportFailure])
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForObservedState { model.state == .failed(.transportFailure) }
        await repository.setFailure(nil, batch: 0)
        let renamed = VideoOwner(id: owner.id, name: "改名后的作者")

        model.open(owner: renamed)
        await waitForLoaded(model, count: 1)

        #expect(model.owner == renamed)
        #expect(await repository.calls.map(\.batch) == [0, 0])
    }

    /// 凭据失效请求一次复核；复核有了确定结果后，停在失败页的第一批自动重载一次，再失败不再自动重载。
    @Test
    func credentialFailureRevalidatesAndReloadsTheFirstBatchOnce() async {
        let repository = UploaderVideoRepositoryStub(failingBatches: [0: .authenticationInvalid])
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForObservedState { model.state == .failed(.authenticationInvalid) }
        #expect(model.authenticationRevalidationGeneration == 1)

        model.authenticationRevalidationConfirmedSignedOut()
        await waitForObservedState { model.authenticationRevalidationGeneration == 2 }
        model.authenticationRevalidationSucceeded()

        #expect(model.state == .failed(.authenticationInvalid))
        #expect(await repository.calls.map(\.batch) == [0, 0])
    }

    /// 提交搜索词换成空间内搜索结果（下一批沿用同一关键词），排序在搜索时不生效；清空搜索从投稿第一批重新读取。
    @Test
    func searchReplacesTheListAndClearingReloadsTheFirstBatch() async {
        let repository = UploaderVideoRepositoryStub()
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, count: 1)

        model.submitSearch("  游戏  ")
        #expect(model.searchKeyword == "游戏")
        await waitForLoaded(model, count: 1)
        model.loadMore()
        await waitForLoaded(model, count: 2)
        model.setOrder(.mostPlayed)
        model.submitSearch("")
        await waitForLoaded(model, count: 1)

        #expect(model.searchKeyword == nil)
        #expect(model.order == .newest)
        #expect(
            await repository.calls == [
                .init(ownerID: 10_001, order: .newest, batch: 0),
                .init(ownerID: 10_001, order: .newest, batch: 0, keyword: "游戏"),
                .init(ownerID: 10_001, order: .newest, batch: 1, keyword: "游戏"),
                .init(ownerID: 10_001, order: .newest, batch: 0)
            ]
        )
    }

    @Test
    func openingAnotherOwnerClearsTheSearch() async {
        let repository = UploaderVideoRepositoryStub()
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, count: 1)
        model.submitSearch("游戏")
        await waitForLoaded(model, count: 1)

        model.open(owner: anotherOwner)
        await waitForLoaded(model, count: 1)

        #expect(model.searchKeyword == nil)
        #expect(await repository.calls.last == .init(ownerID: 10_002, order: .newest, batch: 0))
    }

    @Test
    func closeCancelsTheRequestAndIgnoresItsLateResult() async throws {
        let gate = TestGate()
        let repository = UploaderVideoRepositoryStub(gate: gate, gatedBatches: [0])
        let model = makeModel(repository)

        let stale = SpawnedTasks { model.open(owner: owner) }
        try await gate.waitForEntries()
        model.close()
        try await gate.waitForCancellations()
        await gate.open()
        await stale.finished()

        #expect(model.state == .closed)
        #expect(model.owner == nil)
        #expect(model.totalCount == nil)
    }

    /// 评论正文里的空间链接只有 MID：空间立即打开并加载投稿，名片到达后补上名字与头像。
    @Test
    func idOnlyOpenFillsNameAndAvatarFromTheProfile() async throws {
        let repository = UploaderVideoRepositoryStub()
        let profiles = ProfileRepositoryStub()
        let model = makeModel(repository, profiles: profiles)
        let avatarURL = try #require(URL(string: "https://i0.hdslb.com/bfs/face/fixture.jpg"))

        model.open(ownerID: owner.id)

        #expect(model.owner == VideoOwner(id: owner.id, name: ""))
        await waitForLoaded(model, count: 1)
        await profiles.waitForRequestCount(1)
        await profiles.releaseRequest(
            0,
            profile: UploaderProfile(name: " 作者 ", avatarURL: avatarURL)
        )
        await waitForObservedState { model.owner?.name.isEmpty == false }

        #expect(model.owner == VideoOwner(id: owner.id, name: "作者", avatarURL: avatarURL))
        #expect(await repository.calls == [.init(ownerID: owner.id, order: .newest, batch: 0)])
    }

    /// 链接指向已经打开的 UP 主：保持已加载的投稿与已有资料，不再取名片。
    @Test
    func idOnlyOpenOfTheOpenOwnerKeepsVideosAndProfile() async {
        let repository = UploaderVideoRepositoryStub()
        let profiles = ProfileRepositoryStub(immediate: .success(UploaderProfile(name: "别名")))
        let model = makeModel(repository, profiles: profiles)
        model.open(owner: owner)
        await waitForLoaded(model, count: 1)
        model.loadMore()
        await waitForLoaded(model, count: 2)

        model.open(ownerID: owner.id)

        #expect(model.owner == owner)
        #expect(loadedCount(model) == 2)
        #expect(await profiles.callCount == 0)
    }

    /// 名字还没取到（名片失败或仍在路上）时再次点同一空间链接：重新取名片，不重载投稿。
    @Test
    func idOnlyReopenWithoutANameRequestsTheProfileAgain() async {
        let repository = UploaderVideoRepositoryStub()
        let profiles = ProfileRepositoryStub()
        let model = makeModel(repository, profiles: profiles)
        model.open(ownerID: owner.id)
        await waitForLoaded(model, count: 1)
        await profiles.waitForRequestCount(1)

        model.open(ownerID: owner.id)
        await profiles.waitForRequestCount(2)
        await profiles.releaseRequest(1, profile: UploaderProfile(name: "作者"))
        await waitForObservedState { model.owner?.name.isEmpty == false }

        #expect(model.owner?.name == "作者")
        #expect(await repository.calls.count == 1)
        // 被取代的第一次请求也放行，不留下挂起的 continuation。
        await profiles.releaseRequest(0, profile: UploaderProfile())
    }

    /// 名片只是增强，失败时名字保持为空；但凭据失效仍要交给窗口复核。
    @Test
    func idOnlyProfileCredentialInvalidationRequestsRevalidation() async {
        let repository = UploaderVideoRepositoryStub()
        let profiles = ProfileRepositoryStub(immediate: .failure(.authenticationInvalid))
        let model = makeModel(repository, profiles: profiles)

        model.open(ownerID: owner.id)
        await waitForObservedState { model.authenticationRevalidationGeneration == 1 }

        #expect(model.owner?.name == "")
    }

    @Test(arguments: [Int64(0), -1])
    func idOnlyOpenIgnoresInvalidMemberIDs(_ ownerID: Int64) async {
        let repository = UploaderVideoRepositoryStub()
        let model = makeModel(repository)

        model.open(ownerID: ownerID)

        #expect(model.owner == nil)
        #expect(model.state == .closed)
    }

    @Test
    func sessionChangeDuringLoadMoreClosesTheSpace() async {
        let repository = UploaderVideoRepositoryStub()
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, count: 1)
        await repository.cancelBySessionChange(batch: 1)

        model.loadMore()
        await waitForObservedState { model.state == .closed }

        #expect(model.owner == nil)
    }

    private func makeModel(
        _ repository: UploaderVideoRepositoryStub,
        profiles: ProfileRepositoryStub = ProfileRepositoryStub(
            immediate: .failure(.unavailable)
        )
    ) -> UploaderSpaceViewModel {
        UploaderSpaceViewModel(
            useCase: UploaderVideoUseCase(repository: repository),
            profileUseCase: UploaderProfileUseCase(repository: profiles)
        )
    }

    private func loadedCount(_ model: UploaderSpaceViewModel) -> Int? {
        if case .loaded(let videos) = model.state { return videos.count }
        return nil
    }

    private func waitForLoaded(_ model: UploaderSpaceViewModel, count: Int) async {
        await waitForObservedState { loadedCount(model) == count && model.footer != .loading }
    }
}

/// 本 target 唯一的 `UploaderVideoRepository` 替身：每批一条视频，第 n 批的游标是 "n"，共 `batchCount` 批；可让指定批
/// 失败、挂起或模拟会话切换。
actor UploaderVideoRepositoryStub: UploaderVideoRepository {
    struct Call: Equatable, Sendable {
        let ownerID: Int64
        let order: UploaderVideoOrder
        /// 第几批（0 是第一批，即没有游标）。
        let batch: Int
        /// 空间内搜索的关键词；投稿列表为 nil。
        var keyword: String? = nil
    }

    private(set) var calls: [Call] = []
    private let batchCount: Int
    private var cancellingBatches: Set<Int> = []
    private var failingBatches: [Int: ContentApplicationError]
    private let gate: TestGate?
    private let gatedBatches: Set<Int>

    init(
        batchCount: Int = 3,
        failingBatches: [Int: ContentApplicationError] = [:],
        gate: TestGate? = nil,
        gatedBatches: Set<Int> = []
    ) {
        self.batchCount = batchCount
        self.failingBatches = failingBatches
        self.gate = gate
        self.gatedBatches = gatedBatches
    }

    /// 模拟认证会话在请求途中切换：API 层抛出 CancellationError，而调用方 Task 并未被取消。
    func cancelBySessionChange(batch: Int) {
        cancellingBatches.insert(batch)
    }

    func setFailure(_ error: ContentApplicationError?, batch: Int) {
        failingBatches[batch] = error
    }

    func uploaderVideos(
        ownerID: Int64,
        order: UploaderVideoOrder,
        after cursor: UploaderVideoCursor?
    ) async throws -> UploaderVideoBatch {
        let batch = cursor.flatMap { Int($0.value) } ?? 0
        calls.append(Call(ownerID: ownerID, order: order, batch: batch))
        if let gate, gatedBatches.contains(batch) {
            await gate.pass()
        }
        if cancellingBatches.contains(batch) {
            throw CancellationError()
        }
        if let error = failingBatches[batch] {
            throw error
        }
        return makeBatch(batch)
    }

    func searchUploaderVideos(
        ownerID: Int64,
        keyword: String,
        after cursor: UploaderVideoCursor?
    ) async throws -> UploaderVideoBatch {
        let batch = cursor.flatMap { Int($0.value) } ?? 0
        calls.append(Call(ownerID: ownerID, order: .newest, batch: batch, keyword: keyword))
        return makeBatch(batch)
    }

    private func makeBatch(_ batch: Int) -> UploaderVideoBatch {
        guard batch < batchCount else {
            return UploaderVideoBatch(videos: [], nextCursor: nil, totalCount: 61)
        }
        return UploaderVideoBatch(
            videos: [.testFixture(bvid: "BV1Batch\(batch)Fixtur", title: "第 \(batch) 批")],
            nextCursor: batch + 1 < batchCount
                ? UploaderVideoCursor(value: String(batch + 1)) : nil,
            totalCount: batchCount == 0 ? 0 : 61
        )
    }
}
