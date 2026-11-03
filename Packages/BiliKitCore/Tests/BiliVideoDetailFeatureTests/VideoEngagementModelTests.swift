import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 播放页互动状态：有可写入账户时按展示的视频读取，没有时不读、按钮不可用；换视频先丢掉旧状态；点赞乐观改动与计数，
/// 回滚只放回同一次状态，之后有重读、新详情或投币三连写回时不放回；写入成功时有读取在途就不算已在本地改过；投币与
/// 三连按结果增加且不超过上限，在途的旧读取换成写入之后的重读；重读发现别处的改动时计数随之增减；读取失败后再次展示
/// 同一视频会重读；凭据失败只自动复核重读一次；关注 UP 主与点赞同一套乐观改动与回滚，关注状态未知时不改；自己的视频
/// 不显示关注按钮；别处关注了正在显示的视频的 UP 主时重读。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct VideoEngagementModelTests {
    private static let bvid = "BV17x411w7KC"

    @Test
    func presentingAVideoReadsItsEngagementOnlyWithAnAccount() async {
        let repository = EngagementRepositoryStub()
        let account = MutableAccount()
        let model = makeModel(repository: repository, account: account)

        model.present(detail(Self.bvid))
        #expect(model.phase == .unavailable)
        #expect(model.likeCount == 100)

        account.id = 7
        model.present(detail(Self.bvid))
        await loaded(model)

        #expect(
            model.engagement
                == VideoEngagementState(isLiked: false, coinCount: 1, isFavorited: false)
        )
        #expect(model.remainingCoins == 1)
        #expect(await repository.reads == [Self.bvid])
    }

    @Test
    func anotherVideoDropsTheOldStateBeforeReading() async {
        let model = makeModel(
            repository: EngagementRepositoryStub(),
            account: MutableAccount(id: 7)
        )
        model.present(detail(Self.bvid))
        await loaded(model)

        model.present(detail("BV1xx411c7mD"))

        #expect(model.phase == .loading)
        #expect(model.bvid == "BV1xx411c7mD")
    }

    @Test
    func likeIsOptimisticAndRollsBackToTheSameState() async throws {
        let model = makeModel(
            repository: EngagementRepositoryStub(),
            account: MutableAccount(id: 7)
        )
        model.present(detail(Self.bvid))
        await loaded(model)

        let snapshot = try #require(model.applyLike(true, bvid: Self.bvid))
        #expect(model.engagement?.isLiked == true)
        #expect(model.likeCount == 101)
        #expect(model.stillShows(snapshot))
        #expect(model.applyLike(true, bvid: Self.bvid) == nil)
        #expect(model.applyLike(false, bvid: "BV1xx411c7mD") == nil)

        model.restore(snapshot)
        #expect(model.engagement?.isLiked == false)
        #expect(model.likeCount == 100)
    }

    @Test
    func followIsOptimisticAndRollsBackToTheSameState() async throws {
        let repository = EngagementRepositoryStub()
        await repository.setState(
            VideoEngagementState(
                isLiked: false,
                coinCount: 1,
                isFavorited: false,
                isFollowingUploader: false
            )
        )
        let model = makeModel(repository: repository, account: MutableAccount(id: 7))
        model.present(detail(Self.bvid))
        await loaded(model)

        let snapshot = try #require(model.applyFollow(true, bvid: Self.bvid))
        #expect(model.isFollowingUploader == true)
        #expect(model.stillShows(snapshot))
        #expect(model.applyFollow(true, bvid: Self.bvid) == nil)
        #expect(model.applyFollow(false, bvid: "BV1xx411c7mD") == nil)

        model.restore(snapshot)
        #expect(model.isFollowingUploader == false)
    }

    @Test
    func unknownFollowStateIsNotChanged() async {
        let model = makeModel(
            repository: EngagementRepositoryStub(),
            account: MutableAccount(id: 7)
        )
        model.present(detail(Self.bvid))
        await loaded(model)

        #expect(model.isFollowingUploader == nil)
        #expect(model.applyFollow(true, bvid: Self.bvid) == nil)
        #expect(model.isFollowingUploader == nil)
    }

    @Test
    func followButtonIsHiddenOnlyOnYourOwnVideo() {
        let account = MutableAccount()
        let model = makeModel(repository: EngagementRepositoryStub(), account: account)
        #expect(!model.showsFollowButton)

        model.present(detail(Self.bvid))
        #expect(model.showsFollowButton)
        account.id = 7
        #expect(model.showsFollowButton)
        account.id = 1
        #expect(!model.showsFollowButton)
    }

    @Test
    func followElsewhereReloadsOnlyTheSameUploader() async {
        let repository = EngagementRepositoryStub()
        let model = makeModel(repository: repository, account: MutableAccount(id: 7))
        model.present(detail(Self.bvid))
        await loaded(model)

        await repository.setState(
            VideoEngagementState(
                isLiked: false,
                coinCount: 1,
                isFavorited: false,
                isFollowingUploader: true
            )
        )

        model.markNeedsReload(uploaderID: 99)
        model.markNeedsReload(uploaderID: 1)
        await waitForObservedState { model.isFollowingUploader == true }

        #expect(await repository.reads == [Self.bvid, Self.bvid])
    }

    @Test
    func rollbackAfterAReloadIsDropped() async throws {
        let repository = EngagementRepositoryStub()
        let model = makeModel(repository: repository, account: MutableAccount(id: 7))
        model.present(detail(Self.bvid))
        await loaded(model)
        let snapshot = try #require(model.applyLike(true, bvid: Self.bvid))
        await repository.setState(
            VideoEngagementState(isLiked: true, coinCount: 2, isFavorited: false)
        )

        model.reload()
        #expect(!model.stillShows(snapshot))
        await waitForObservedState { model.engagement?.coinCount == 2 }
        model.restore(snapshot)

        #expect(
            model.engagement
                == VideoEngagementState(isLiked: true, coinCount: 2, isFavorited: false)
        )
        #expect(model.likeCount == 101)
    }

    @Test
    func rollbackAfterACoinWriteIsDropped() async throws {
        let model = makeModel(
            repository: EngagementRepositoryStub(),
            account: MutableAccount(id: 7)
        )
        model.present(detail(Self.bvid))
        await loaded(model)
        let snapshot = try #require(model.applyLike(true, bvid: Self.bvid))

        model.applyCoins(1, alsoLiked: false, bvid: Self.bvid)
        model.restore(snapshot)

        #expect(
            model.engagement
                == VideoEngagementState(isLiked: true, coinCount: 2, isFavorited: false)
        )
        #expect(model.coinCount == 21)
    }

    @Test
    func coinsAndTripleAddTheirResultsWithinTheLimit() async {
        let model = makeModel(
            repository: EngagementRepositoryStub(),
            account: MutableAccount(id: 7)
        )
        model.present(detail(Self.bvid))
        await loaded(model)

        model.applyCoins(1, alsoLiked: true, bvid: Self.bvid)
        #expect(
            model.engagement
                == VideoEngagementState(isLiked: true, coinCount: 2, isFavorited: false)
        )
        #expect(model.coinCount == 21)
        #expect(model.likeCount == 101)
        #expect(model.remainingCoins == 0)

        model.applyTriple(
            VideoTripleOutcome(isLiked: true, isCoined: true, isFavorited: true, addedCoinCount: 2),
            bvid: Self.bvid
        )
        #expect(
            model.engagement == VideoEngagementState(isLiked: true, coinCount: 2, isFavorited: true)
        )
        #expect(model.favoriteCount == 31)
        #expect(model.likeCount == 101)
        #expect(model.coinCount == 21)
    }

    @Test
    func aWriteReplacesTheReadThatWasInFlight() async throws {
        let repository = EngagementRepositoryStub()
        let model = makeModel(repository: repository, account: MutableAccount(id: 7))
        model.present(detail(Self.bvid))
        await loaded(model)
        let snapshot = try #require(model.applyLike(true, bvid: Self.bvid))
        await repository.holdReads()
        model.reload()
        await repository.waitForReadCount(2)
        #expect(!model.stillShows(snapshot))

        await repository.setState(
            VideoEngagementState(isLiked: true, coinCount: 2, isFavorited: true)
        )
        model.applyCoins(1, alsoLiked: false, bvid: Self.bvid)
        await repository.waitForReadCount(3)
        await repository.releaseReads()
        await waitForObservedState { model.engagement?.isFavorited == true }

        #expect(
            model.engagement == VideoEngagementState(isLiked: true, coinCount: 2, isFavorited: true)
        )
        #expect(model.coinCount == 21)
        #expect(model.likeCount == 101)
        #expect(model.favoriteCount == 31)
    }

    @Test
    func reloadCarriesChangesMadeElsewhereIntoTheCounts() async {
        let repository = EngagementRepositoryStub()
        let model = makeModel(repository: repository, account: MutableAccount(id: 7))
        model.present(detail(Self.bvid))
        await loaded(model)
        await repository.setState(
            VideoEngagementState(isLiked: true, coinCount: 1, isFavorited: true)
        )

        model.markNeedsReload(bvid: "BV1xx411c7mD")
        model.markNeedsReload(bvid: Self.bvid)
        await waitForObservedState { model.engagement?.isLiked == true }

        #expect(model.likeCount == 101)
        #expect(model.favoriteCount == 31)
        #expect(await repository.reads.count == 2)
    }

    @Test
    func aFailedReadRetriesWhenTheVideoIsPresentedAgain() async {
        let repository = EngagementRepositoryStub()
        await repository.setFailure(.unavailable)
        let model = makeModel(repository: repository, account: MutableAccount(id: 7))
        model.present(detail(Self.bvid))
        await waitForObservedState { model.phase == .failed(.unavailable) }

        await repository.setFailure(nil)
        model.present(detail(Self.bvid))
        await loaded(model)

        #expect(await repository.reads.count == 2)
    }

    @Test
    func credentialFailureRequestsOneRevalidationReload() async {
        let repository = EngagementRepositoryStub()
        await repository.setFailure(.authenticationInvalid)
        let model = makeModel(repository: repository, account: MutableAccount(id: 7))
        model.present(detail(Self.bvid))
        await waitForObservedState { model.phase == .failed(.authenticationInvalid) }
        #expect(model.authenticationRevalidationGeneration == 1)

        model.authenticationRevalidationSucceeded()
        await repository.waitForReadCount(2)
        model.authenticationRevalidationSucceeded()

        #expect(model.authenticationRevalidationGeneration == 1)
        #expect(await repository.reads.count == 2)
    }

    private func makeModel(
        repository: EngagementRepositoryStub,
        account: MutableAccount
    ) -> VideoEngagementModel {
        VideoEngagementModel(
            useCase: VideoEngagementUseCase(repository: repository),
            accountID: { account.id }
        )
    }

    private func loaded(_ model: VideoEngagementModel) async {
        await waitForObservedState { model.engagement != nil }
    }

    private func detail(_ bvid: String) -> VideoDetail {
        makeVideoDetail(
            bvid: bvid,
            title: "标题",
            summary: "",
            statistics: VideoStatistics(viewCount: 1_000, danmakuCount: 10, likeCount: 100),
            durationSeconds: 60,
            pages: [],
            engagementSummary: VideoEngagementSummary(
                coinCount: 20,
                favoriteCount: 30,
                isReposted: false
            )
        )
    }
}

/// 测试里可变的写入账户；闭包在主线程读取。
@MainActor
private final class MutableAccount {
    var id: Int64?

    init(id: Int64? = nil) {
        self.id = id
    }
}

/// 本 target 唯一的 `VideoEngagementRepository` 替身：读取返回可替换的状态（或失败）并记录，可挂起到放行；写入不在
/// 这里测试。
private actor EngagementRepositoryStub: VideoEngagementRepository {
    private var state = VideoEngagementState(isLiked: false, coinCount: 1, isFavorited: false)
    private var failure: ContentApplicationError?
    private var holdsReads = false
    private var heldReads: [CheckedContinuation<Void, Never>] = []
    private var readWaiters = CountWaiters()
    private(set) var reads: [String] = []

    func setState(_ state: VideoEngagementState) {
        self.state = state
    }

    func setFailure(_ failure: ContentApplicationError?) {
        self.failure = failure
    }

    func holdReads() {
        holdsReads = true
    }

    func releaseReads() {
        holdsReads = false
        heldReads.resumeAll()
    }

    func waitForReadCount(_ count: Int) async {
        await withCheckedContinuation {
            readWaiters.add($0, until: count, current: reads.count)
        }
    }

    func engagement(of target: VideoWriteTarget) async throws -> VideoEngagementState {
        reads.append(target.bvid)
        readWaiters.resume(reaching: reads.count)
        if holdsReads {
            await withCheckedContinuation { heldReads.append($0) }
        }
        if let failure { throw failure }
        return state
    }

    func setLiked(_ isLiked: Bool, target: VideoWriteTarget, accountID: Int64) async throws {}

    func addCoins(
        _ count: Int,
        alsoLike: Bool,
        target: VideoWriteTarget,
        accountID: Int64
    ) async throws -> Bool { alsoLike }

    func triple(target: VideoWriteTarget, accountID: Int64) async throws -> VideoTripleOutcome {
        VideoTripleOutcome(isLiked: true, isCoined: true, isFavorited: true, addedCoinCount: 2)
    }

    func setFollowing(
        _ isFollowing: Bool,
        uploader: UploaderWriteTarget,
        accountID: Int64
    ) async throws {}
}
