import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// UP 主空间视图模型的翻页、排序与重开规则。
///
/// 打开时读最新排序第 1 页；同一 UP 主再次打开保持当前页并更新资料、失败时顺带重试，换 UP 主回到默认排序与第 1 页，
/// 换排序回到第 1 页；越界或正在显示／加载的页不发请求，重载与另选页取代在途请求，旧请求与关闭后的迟到结果不写回；
/// 页数在翻页与失败期间保持，总数变少时落到最后一页；只有 MID 的入口先打开、名片到达后补名字；未登录给登录入口，
/// 凭据失效请求窗口复核，会话在请求途中切换时关闭空间。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct UploaderSpaceViewModelTests {
    private let owner = VideoOwner(id: 10_001, name: "作者")
    private let anotherOwner = VideoOwner(id: 10_002, name: "另一位作者")

    @Test
    func openLoadsFirstPageOfNewest() async {
        let repository = UploaderVideoRepositoryStub()
        let model = makeModel(repository)

        model.open(owner: owner)
        #expect(model.state == .loading(page: 1))
        await waitForLoaded(model, page: 1)

        #expect(model.owner == owner)
        #expect(model.pageCount == 3)
        #expect(model.totalCount == 61)
        #expect(await repository.calls == [.init(ownerID: 10_001, order: .newest, page: 1)])
    }

    @Test
    func reopeningTheSameOwnerKeepsCurrentPage() async {
        let repository = UploaderVideoRepositoryStub()
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, page: 1)
        model.showPage(2)
        await waitForLoaded(model, page: 2)

        model.open(owner: owner)

        #expect(model.currentPage == 2)
        #expect(await repository.calls.count == 2)
    }

    @Test
    func openingAnotherOwnerResetsOrderAndPage() async {
        let repository = UploaderVideoRepositoryStub()
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, page: 1)
        model.setOrder(.mostPlayed)
        await waitForLoaded(model, page: 1)
        model.showPage(3)
        await waitForLoaded(model, page: 3)

        model.open(owner: anotherOwner)
        await waitForLoaded(model, page: 1)

        #expect(model.order == .newest)
        #expect(await repository.calls.last == .init(ownerID: 10_002, order: .newest, page: 1))
    }

    @Test
    func changingOrderReturnsToFirstPage() async {
        let repository = UploaderVideoRepositoryStub()
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, page: 1)
        model.showPage(2)
        await waitForLoaded(model, page: 2)

        model.setOrder(.mostFavorited)
        await waitForLoaded(model, page: 1)

        #expect(
            await repository.calls.last == .init(ownerID: 10_001, order: .mostFavorited, page: 1)
        )
    }

    @Test(arguments: [0, 4, 1])
    func pagesOutOfRangeOrAlreadyShownSendNothing(page: Int) async {
        let repository = UploaderVideoRepositoryStub()
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, page: 1)

        model.showPage(page)

        #expect(model.currentPage == 1)
        #expect(await repository.calls.count == 1)
    }

    @Test
    func pageCountStaysWhileTheNextPageLoadsAndAfterItFails() async {
        let repository = UploaderVideoRepositoryStub(failingPages: [2: .transportFailure])
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, page: 1)

        model.showPage(2)
        #expect(model.state == .loading(page: 2))
        #expect(model.pageCount == 3)
        await waitForObservedState { model.state == .failed(page: 2, error: .transportFailure) }

        #expect(model.pageCount == 3)
        #expect(model.totalCount == 61)
    }

    @Test
    func failedPageRetriesTheSamePage() async {
        let repository = UploaderVideoRepositoryStub(failingPages: [2: .transportFailure])
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, page: 1)
        model.showPage(2)
        await waitForObservedState { model.state == .failed(page: 2, error: .transportFailure) }
        await repository.setFailure(nil, page: 2)

        model.reload()
        await waitForLoaded(model, page: 2)

        #expect(await repository.calls.map(\.page) == [1, 2, 2])
    }

    /// 未登录给出登录入口、不复核；凭据失效不给登录入口，请求窗口复核。
    @Test(
        arguments: [
            (ContentApplicationError.authenticationRequired, true, 0),
            (.authenticationInvalid, false, 1)
        ]
    )
    func loginFailuresAskForSignInOrRevalidation(
        error: ContentApplicationError,
        requiresAuthentication: Bool,
        revalidations: Int
    ) async {
        let repository = UploaderVideoRepositoryStub(failingPages: [1: error])
        let model = makeModel(repository)

        model.open(owner: owner)
        await waitForObservedState { model.state != .loading(page: 1) }

        #expect(model.requiresAuthentication == requiresAuthentication)
        #expect(model.authenticationRevalidationGeneration == revalidations)
    }

    @Test
    func closeCancelsTheRequestAndIgnoresItsLateResult() async throws {
        let gate = TestGate()
        let repository = UploaderVideoRepositoryStub(gate: gate, gatedPages: [1])
        let model = makeModel(repository)

        let stale = SpawnedTasks { model.open(owner: owner) }
        try await gate.waitForEntries()
        model.close()
        try await gate.waitForCancellations()
        await gate.open()
        await stale.finished()

        #expect(model.state == .closed)
        #expect(model.owner == nil)
        #expect(model.pageCount == 1)
    }

    @Test
    func emptySpaceLoadsAnEmptyFirstPage() async {
        let repository = UploaderVideoRepositoryStub(totalCount: 0)
        let model = makeModel(repository)

        model.open(owner: owner)
        await waitForObservedState { model.state != .loading(page: 1) }

        guard case .loaded(let page) = model.state else {
            Issue.record("expected a loaded empty page, got \(model.state)")
            return
        }
        #expect(page.videos.isEmpty)
        #expect(model.pageCount == 1)
    }

    @Test
    func reopeningTheSameOwnerRefreshesProfileAndRetriesAFailure() async {
        let repository = UploaderVideoRepositoryStub(failingPages: [1: .transportFailure])
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForObservedState { model.state == .failed(page: 1, error: .transportFailure) }
        await repository.setFailure(nil, page: 1)
        let renamed = VideoOwner(id: owner.id, name: "改名后的作者")

        model.open(owner: renamed)
        await waitForLoaded(model, page: 1)

        #expect(model.owner == renamed)
        #expect(await repository.calls.map(\.page) == [1, 1])
    }

    @Test
    func requestingThePageThatIsLoadingSendsNothingButAnotherPageReplacesIt() async throws {
        let gate = TestGate()
        let repository = UploaderVideoRepositoryStub(gate: gate, gatedPages: [2])
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, page: 1)

        let stale = SpawnedTasks { model.showPage(2) }
        try await gate.waitForEntries()
        model.showPage(2)
        #expect(await repository.calls.map(\.page) == [1, 2])

        model.showPage(3)
        try await gate.waitForCancellations()
        await waitForLoaded(model, page: 3)
        await gate.open()
        await stale.finished()

        #expect(model.currentPage == 3)
        #expect(await repository.calls.map(\.page) == [1, 2, 3])
    }

    @Test
    func reloadWhileLoadingRestartsTheSamePage() async throws {
        let gate = TestGate()
        let repository = UploaderVideoRepositoryStub(gate: gate, gatedPages: [2])
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, page: 1)
        model.showPage(2)
        try await gate.waitForEntries()

        model.reload()
        try await gate.waitForCancellations()
        await gate.open()
        await waitForLoaded(model, page: 2)

        #expect(await repository.calls.map(\.page) == [1, 2, 2])
    }

    @Test
    func shrinkingTotalFallsBackToTheLastPage() async {
        let repository = UploaderVideoRepositoryStub()
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, page: 1)
        await repository.setTotalCount(59)

        model.showPage(3)
        await waitForLoaded(model, page: 2)

        #expect(model.pageCount == 2)
        #expect(model.currentPage <= model.pageCount)
        #expect(await repository.calls.map(\.page) == [1, 3, 2])
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
        await waitForLoaded(model, page: 1)
        await profiles.waitForRequestCount(1)
        await profiles.releaseRequest(
            0,
            profile: UploaderProfile(name: " 作者 ", avatarURL: avatarURL)
        )
        await waitForObservedState { model.owner?.name.isEmpty == false }

        #expect(model.owner == VideoOwner(id: owner.id, name: "作者", avatarURL: avatarURL))
        #expect(await repository.calls == [.init(ownerID: owner.id, order: .newest, page: 1)])
    }

    /// 链接指向已经打开的 UP 主：保持当前页与已有资料，不再取名片。
    @Test
    func idOnlyOpenOfTheOpenOwnerKeepsPageAndProfile() async {
        let repository = UploaderVideoRepositoryStub()
        let profiles = ProfileRepositoryStub(immediate: .success(UploaderProfile(name: "别名")))
        let model = makeModel(repository, profiles: profiles)
        model.open(owner: owner)
        await waitForLoaded(model, page: 1)
        model.showPage(2)
        await waitForLoaded(model, page: 2)

        model.open(ownerID: owner.id)

        #expect(model.owner == owner)
        #expect(model.currentPage == 2)
        #expect(await profiles.callCount == 0)
    }

    /// 名字还没取到（名片失败或仍在路上）时再次点同一空间链接：重新取名片，不重载投稿。
    @Test
    func idOnlyReopenWithoutANameRequestsTheProfileAgain() async {
        let repository = UploaderVideoRepositoryStub()
        let profiles = ProfileRepositoryStub()
        let model = makeModel(repository, profiles: profiles)
        model.open(ownerID: owner.id)
        await waitForLoaded(model, page: 1)
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
    func sessionChangeDuringARequestClosesTheSpace() async {
        let repository = UploaderVideoRepositoryStub()
        let model = makeModel(repository)
        model.open(owner: owner)
        await waitForLoaded(model, page: 1)
        await repository.cancelBySessionChange(page: 2)

        model.showPage(2)
        await waitForObservedState { model.state == .closed }

        #expect(model.owner == nil)
        #expect(model.pageCount == 1)
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

    private func waitForLoaded(_ model: UploaderSpaceViewModel, page: Int) async {
        await waitForObservedState {
            if case .loaded(let loaded) = model.state { return loaded.pageNumber == page }
            return false
        }
    }
}

/// 本 target 唯一的 `UploaderVideoRepository` 替身：按页返回一条视频，可让指定页失败或挂起。
actor UploaderVideoRepositoryStub: UploaderVideoRepository {
    struct Call: Equatable, Sendable {
        let ownerID: Int64
        let order: UploaderVideoOrder
        let page: Int
    }

    private(set) var calls: [Call] = []
    private var totalCount: Int
    private var cancellingPages: Set<Int> = []
    private var failingPages: [Int: ContentApplicationError]
    private let gate: TestGate?
    private let gatedPages: Set<Int>

    init(
        totalCount: Int = 61,
        failingPages: [Int: ContentApplicationError] = [:],
        gate: TestGate? = nil,
        gatedPages: Set<Int> = []
    ) {
        self.totalCount = totalCount
        self.failingPages = failingPages
        self.gate = gate
        self.gatedPages = gatedPages
    }

    func setTotalCount(_ count: Int) {
        totalCount = count
    }

    /// 模拟认证会话在请求途中切换：API 层抛出 CancellationError，而调用方 Task 并未被取消。
    func cancelBySessionChange(page: Int) {
        cancellingPages.insert(page)
    }

    func setFailure(_ error: ContentApplicationError?, page: Int) {
        failingPages[page] = error
    }

    func uploaderVideos(
        ownerID: Int64,
        order: UploaderVideoOrder,
        page: Int
    ) async throws -> UploaderVideoPage {
        calls.append(Call(ownerID: ownerID, order: order, page: page))
        if let gate, gatedPages.contains(page) {
            await gate.pass()
        }
        if cancellingPages.contains(page) {
            throw CancellationError()
        }
        if let error = failingPages[page] {
            throw error
        }
        let videos: [UploaderVideo] =
            totalCount == 0
            ? []
            : [.testFixture(bvid: "BV1Page\(page)Fixture", title: "第 \(page) 页")]
        return UploaderVideoPage(
            videos: videos,
            pageNumber: page,
            pageSize: 30,
            totalCount: totalCount
        )
    }
}
