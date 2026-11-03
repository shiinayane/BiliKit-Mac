import BiliApplication
import Foundation
import Testing

/// 点赞、投币、三连与关注只为正数账户发请求，投币只收 1 或 2 枚，不关注自己；成功时给出带账户的效果，投币效果带服务端
/// 报告的附带点赞，三连效果带逐项结果；可投币数按转载与否的上限减去已投数；只有被 B 站拒绝的点赞、投币与三连给出在浏览器
/// 中打开的视频。
@Suite(.timeLimit(.minutes(1)))
struct VideoEngagementUseCaseTests {
    @Test
    func successfulWritesReportTheirEffect() async throws {
        let outcome = VideoTripleOutcome(
            isLiked: true,
            isCoined: true,
            isFavorited: true,
            addedCoinCount: 1
        )
        let repository = VideoEngagementRepositoryStub(coinLike: false, outcome: outcome)
        let useCase = VideoEngagementUseCase(repository: repository)
        let target = try #require(VideoWriteTarget(bvid: "BV17x411w7KC"))

        let liked = try await useCase.setLiked(true, target: target, accountID: 42)
        let coined = try await useCase.addCoins(2, alsoLike: true, target: target, accountID: 42)
        let tripled = try await useCase.triple(target: target, accountID: 42)
        let uploader = try #require(UploaderWriteTarget(mid: 7))
        let followed = try await useCase.setFollowing(true, uploader: uploader, accountID: 42)

        #expect(
            liked == AccountWriteEffect(accountID: 42, change: .likeChanged(target, isLiked: true))
        )
        // 请求了同时点赞，服务端报告点赞没有成立：效果以服务端为准。
        #expect(
            coined
                == AccountWriteEffect(
                    accountID: 42,
                    change: .coinsAdded(target, count: 2, alsoLiked: false)
                )
        )
        #expect(tripled == AccountWriteEffect(accountID: 42, change: .tripled(target, outcome)))
        #expect(
            followed
                == AccountWriteEffect(
                    accountID: 42,
                    change: .followChanged(uploader, isFollowing: true)
                )
        )
        #expect(await repository.calls == ["like", "coin 2 +like", "triple", "follow 7"])
    }

    @Test(arguments: [(Int64(42), Int64(42)), (7, 0), (7, -1)])
    func followingYourselfOrWithoutAnAccountSendsNothing(
        mid: Int64,
        accountID: Int64
    ) async throws {
        let repository = VideoEngagementRepositoryStub()
        let useCase = VideoEngagementUseCase(repository: repository)
        let uploader = try #require(UploaderWriteTarget(mid: mid))

        await #expect(throws: AccountWriteError.invalidRequest) {
            try await useCase.setFollowing(true, uploader: uploader, accountID: accountID)
        }
        #expect(await repository.calls.isEmpty)
        #expect(UploaderWriteTarget(mid: 0) == nil)
    }

    @Test(arguments: [(0, Int64(42)), (3, 42), (1, 0), (1, -7)])
    func invalidCoinCountOrAccountSendsNothing(count: Int, accountID: Int64) async throws {
        let repository = VideoEngagementRepositoryStub()
        let useCase = VideoEngagementUseCase(repository: repository)
        let target = try #require(VideoWriteTarget(bvid: "BV17x411w7KC"))

        await #expect(throws: AccountWriteError.invalidRequest) {
            try await useCase.addCoins(count, alsoLike: false, target: target, accountID: accountID)
        }
        #expect(await repository.calls.isEmpty)
    }

    @Test
    func onlyDeclinedEngagementOffersTheWebFallback() throws {
        let target = try #require(VideoWriteTarget(bvid: "BV17x411w7KC"))
        let declined: [AccountWriteChange] = [
            .likeChanged(target, isLiked: true),
            .coinsAdded(target, count: 1, alsoLiked: false),
            .tripled(target, nil)
        ]

        for change in declined {
            #expect(
                AccountWriteReport(change: change, failure: .declinedForClient).webFallbackURL?
                    .absoluteString == "https://www.bilibili.com/video/BV17x411w7KC"
            )
            #expect(
                AccountWriteReport(change: change, failure: .restricted).webFallbackURL == nil
            )
            #expect(AccountWriteReport(change: change, failure: nil).webFallbackURL == nil)
        }
        let uploader = try #require(UploaderWriteTarget(mid: 7))
        let feedback = try #require(
            RecommendationFeedback(target: target, uploaderID: 7, trackID: "t", reason: .content)
        )
        let others: [AccountWriteChange] = [
            .watchLaterAdded(target),
            .followChanged(uploader, isFollowing: true),
            .recommendationDisliked(feedback)
        ]
        for change in others {
            #expect(
                AccountWriteReport(change: change, failure: .declinedForClient).webFallbackURL
                    == nil
            )
        }
    }

    @Test(arguments: [
        (false, 0, 2), (false, 1, 1), (false, 2, 0), (true, 0, 1), (true, 1, 0), (true, 2, 0)
    ])
    func remainingCoinsFollowTheRepostLimit(isReposted: Bool, coinCount: Int, remaining: Int) {
        #expect(
            VideoCoinRule.remainingCoins(isReposted: isReposted, coinCount: coinCount) == remaining
        )
    }
}

/// 本 target 唯一的 `VideoEngagementRepository` 替身：记录写入，投币返回配置的附带点赞结果，三连返回配置的结果。
private actor VideoEngagementRepositoryStub: VideoEngagementRepository {
    private let coinLike: Bool
    private let outcome: VideoTripleOutcome
    private(set) var calls: [String] = []

    init(
        coinLike: Bool = true,
        outcome: VideoTripleOutcome = VideoTripleOutcome(
            isLiked: true,
            isCoined: true,
            isFavorited: true,
            addedCoinCount: 2
        )
    ) {
        self.coinLike = coinLike
        self.outcome = outcome
    }

    func engagement(of target: VideoWriteTarget) async throws -> VideoEngagementState {
        VideoEngagementState(isLiked: false, coinCount: 0, isFavorited: false)
    }

    func setLiked(_ isLiked: Bool, target: VideoWriteTarget, accountID: Int64) async throws {
        calls.append(isLiked ? "like" : "unlike")
    }

    func addCoins(
        _ count: Int,
        alsoLike: Bool,
        target: VideoWriteTarget,
        accountID: Int64
    ) async throws -> Bool {
        calls.append("coin \(count)\(alsoLike ? " +like" : "")")
        return coinLike
    }

    func triple(target: VideoWriteTarget, accountID: Int64) async throws -> VideoTripleOutcome {
        calls.append("triple")
        return outcome
    }

    func setFollowing(
        _ isFollowing: Bool,
        uploader: UploaderWriteTarget,
        accountID: Int64
    ) async throws {
        calls.append("\(isFollowing ? "follow" : "unfollow") \(uploader.mid)")
    }
}
