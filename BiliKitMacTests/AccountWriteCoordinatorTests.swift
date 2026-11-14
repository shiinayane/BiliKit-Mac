import BiliAPI
import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import BiliModels
import BiliVideoDetailFeature
import Foundation
import Observation
import Testing

@testable import BiliKit

/// 账户写入只在窗口账户可信（已登录且 mid 已知、不在复核、没有待复核的外部换号）时发出，并绑定该账户；成功后给出结果
/// 并让本窗口与其他窗口的稍后再看在下次出现时刷新（本窗口乐观移除过的不再刷新）；稍后再看页与收藏夹页的移除先在本地
/// 删掉、失败放回原位；「收藏到…」面板确认时只提交勾选的差异，成功后侧栏收藏夹重读；窗口账户一变面板就关闭，重试与
/// 确认也不在另一个账户下进行；播放页点赞乐观改动、失败放回，反方向的点赞在途时不再发，投币与三连成功后才改状态、三连
/// 刷新收藏夹；首页推荐的「不感兴趣」与撤销先改卡片标记、失败放回，同一视频的两者同时只发一个，不在推荐里的不发；
/// 快捷键在未登录、状态未知与全屏时给出提示；加入稍后再看报告是否发出；写入或面板读取的凭据类失败只请求一次复核，直到下一次写入成功；
/// 弹幕同一窗口同时只有一条在途、结局交回输入胶囊而不进结果胶囊、关窗时按取消结束；关窗后不再接受意图。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AccountWriteCoordinatorTests {
    @Test(arguments: [
        (AccountSessionScope.signedIn(accountID: 7), false, AccountSessionScope.unresolved, true),
        (.signedIn(accountID: 7), false, .signedIn(accountID: 7), true),
        (.signedIn(accountID: 7), true, .signedIn(accountID: 7), false),
        (.signedIn(accountID: nil), false, .unresolved, false),
        (.signedOut, false, .signedOut, false),
        (.unresolved, false, .unresolved, false),
        (.signedIn(accountID: 7), false, .signedIn(accountID: 8), false)
    ])
    func writesNeedASettledSignedInAccount(
        windowScope: AccountSessionScope,
        isRestoring: Bool,
        processScope: AccountSessionScope,
        writable: Bool
    ) {
        let accountSession = AccountSessionCoordinator()
        accountSession.publish(processScope)

        let account = WindowComposition.writableAccount(
            windowScope: windowScope,
            isRestoring: isRestoring,
            accountSession: accountSession
        )

        #expect(
            account
                == (writable
                    ? WritableAccount(accountID: 7, sessionGeneration: accountSession.generation)
                    : nil)
        )
    }

    @Test
    func addReportsSuccessAndMarksEveryWatchLaterListStale() async throws {
        let process = makeTestProcess()
        let writes = AccountWriteRepositoryStub()
        let origin = try await signedInWindow(process: process, writes: writes)
        let other = try await signedInWindow(process: process)
        defer {
            origin.close()
            other.close()
        }
        await load(origin.watchLaterModel)
        await load(other.watchLaterModel)
        let originGeneration = origin.watchLaterModel.successfulReloadGeneration
        let otherGeneration = other.watchLaterModel.successfulReloadGeneration

        #expect(origin.accountWrites.isWritable)
        origin.accountWrites.addToWatchLater(bvid: "BV17x411w7KC")
        await waitForObservedState { origin.accountWrites.report != nil }

        #expect(await writes.calls == ["add BV17x411w7KC 7"])
        #expect(
            origin.accountWrites.report
                == AccountWriteReport(change: .watchLaterAdded(try target()), failure: nil)
        )
        // 只标记过期：下次页面出现时才读取。
        #expect(origin.watchLaterModel.successfulReloadGeneration == originGeneration)
        await load(origin.watchLaterModel)
        await load(other.watchLaterModel)
        #expect(origin.watchLaterModel.successfulReloadGeneration == originGeneration &+ 1)
        #expect(other.watchLaterModel.successfulReloadGeneration == otherGeneration &+ 1)
    }

    @Test
    func removalIsOptimisticAndRollsBackOnFailure() async throws {
        let writes = AccountWriteRepositoryStub(outcomes: [.listFull, nil])
        let window = try await signedInWindow(
            process: makeTestProcess(),
            writes: writes,
            watchLater: ["BV17x411w7KC", "BV1xx411c7mD"]
        )
        defer { window.close() }
        await load(window.watchLaterModel)

        window.accountWrites.removeFromWatchLater(bvid: "BV17x411w7KC")
        #expect(bvids(window.watchLaterModel) == ["BV1xx411c7mD"])
        await waitForObservedState { window.accountWrites.report != nil }
        #expect(bvids(window.watchLaterModel) == ["BV17x411w7KC", "BV1xx411c7mD"])
        #expect(window.accountWrites.report?.failure == .listFull)
        #expect(window.accountWrites.authenticationRevalidationGeneration == 0)

        let generation = window.watchLaterModel.successfulReloadGeneration
        let sequence = window.accountWrites.reportSequence
        window.accountWrites.removeFromWatchLater(bvid: "BV17x411w7KC")
        await waitForObservedState { window.accountWrites.reportSequence != sequence }
        #expect(window.accountWrites.report?.failure == nil)
        #expect(bvids(window.watchLaterModel) == ["BV1xx411c7mD"])
        // 本窗口已经乐观移除，成功后不再标记过期、不再刷新。
        await load(window.watchLaterModel)
        #expect(window.watchLaterModel.successfulReloadGeneration == generation)
        #expect(await writes.calls == ["remove BV17x411w7KC 7", "remove BV17x411w7KC 7"])
    }

    @Test
    func credentialFailuresRequestOneRevalidationUntilAWriteSucceeds() async throws {
        let writes = AccountWriteRepositoryStub(
            outcomes: [.authenticationInvalid, .authenticationRequired, nil, .authenticationInvalid]
        )
        let window = try await signedInWindow(process: makeTestProcess(), writes: writes)
        defer { window.close() }
        let coordinator = window.accountWrites
        let expectedGenerations = [1, 1, 1, 2]

        for expected in expectedGenerations {
            let sequence = coordinator.reportSequence
            coordinator.addToWatchLater(bvid: "BV17x411w7KC")
            await waitForObservedState { coordinator.reportSequence != sequence }
            #expect(coordinator.authenticationRevalidationGeneration == expected)
        }
    }

    /// 节流只在同一账户与会话代次里生效：换号或登出再登录后，第一次凭据类失败照常请求复核。
    @Test
    func revalidationThrottleExpiresWithTheSession() async throws {
        let writes = AccountWriteRepositoryStub(
            outcomes: [.authenticationInvalid, .authenticationInvalid, .authenticationInvalid]
        )
        let session = MutableWritableAccount()
        let coordinator = standaloneCoordinator(writes: writes, session: session)
        defer { coordinator.close() }

        for (generation, expected) in [(UInt64(1), 1), (1, 1), (3, 2)] {
            session.account = WritableAccount(accountID: 7, sessionGeneration: generation)
            let sequence = coordinator.reportSequence
            coordinator.addToWatchLater(bvid: "BV17x411w7KC")
            await waitForObservedState { coordinator.reportSequence != sequence }
            #expect(coordinator.authenticationRevalidationGeneration == expected)
        }
    }

    /// 加入稍后再看报告是否发出：同一视频已在途时不再发，播放器动作菜单据此不给提示。
    @Test
    func watchLaterAddReportsWhetherItWasSent() async throws {
        let writes = AccountWriteRepositoryStub()
        let window = try await signedInWindow(process: makeTestProcess(), writes: writes)
        defer { window.close() }
        let coordinator = window.accountWrites
        let sequence = coordinator.reportSequence

        #expect(coordinator.addToWatchLater(bvid: "BV17x411w7KC"))
        #expect(!coordinator.addToWatchLater(bvid: "BV17x411w7KC"))
        await waitForObservedState { coordinator.reportSequence != sequence }
        #expect(await writes.calls.count == 1)
    }

    @Test
    func closedGateSendsNothing() async throws {
        let writes = AccountWriteRepositoryStub()
        let window = WindowComposition(
            process: makeTestProcess(),
            adapters: makeTestAdapters(watchLaterWrite: writes)
        )
        window.authenticationModel.restoreIfNeeded()
        await window.authenticationModel.waitForCurrentTask()

        #expect(!window.accountWrites.isWritable)
        #expect(!window.accountWrites.addToWatchLater(bvid: "BV17x411w7KC"))
        window.accountWrites.removeFromWatchLater(bvid: "BV17x411w7KC")
        window.accountWrites.chooseFavoriteFolders(bvid: "BV17x411w7KC")
        #expect(window.accountWrites.favoritePicker == nil)
        window.close()

        #expect(await writes.calls.isEmpty)
        #expect(window.accountWrites.report == nil)
    }

    /// 其他账户或旧会话代次的效果不落到本窗口。
    @Test
    func effectsOfAnotherAccountOrSessionAreDropped() async throws {
        let window = try await signedInWindow(process: makeTestProcess())
        defer { window.close() }
        await load(window.watchLaterModel)
        let generation = window.watchLaterModel.successfulReloadGeneration
        let router = AccountWriteEffectRouter(
            watchLaterModel: window.watchLaterModel,
            favoriteFolderList: window.favoriteFolderList,
            favoriteFolders: window.favoriteFolders,
            engagementModel: window.engagementModel,
            writableAccount: { WritableAccount(accountID: 7, sessionGeneration: 3) }
        )

        for delivery in [
            AccountWriteEffectDelivery(
                effect: AccountWriteEffect(accountID: 8, change: .watchLaterAdded(try target())),
                sessionGeneration: 3
            ),
            AccountWriteEffectDelivery(
                effect: AccountWriteEffect(accountID: 7, change: .watchLaterAdded(try target())),
                sessionGeneration: 2
            )
        ] {
            router.apply(delivery, appliedLocally: false)
        }
        await load(window.watchLaterModel)

        #expect(window.watchLaterModel.successfulReloadGeneration == generation)
    }

    /// 关窗取消在途写入：之后不显示结果，也不再接受新的意图。
    @Test
    func closingCancelsInFlightWrites() async throws {
        let writes = AccountWriteRepositoryStub(holdsWrites: true)
        let window = try await signedInWindow(process: makeTestProcess(), writes: writes)

        window.accountWrites.addToWatchLater(bvid: "BV17x411w7KC")
        await writes.waitForCallCount(1)
        window.close()
        await writes.releaseWrites()
        window.accountWrites.addToWatchLater(bvid: "BV1xx411c7mD")

        #expect(!window.accountWrites.isWritable)
        #expect(window.accountWrites.report == nil)
        #expect(await writes.calls == ["add BV17x411w7KC 7"])
    }

    @Test
    func pickerConfirmsOnlyTheDifferenceAndRefreshesTheFolderList() async throws {
        let writes = AccountWriteRepositoryStub()
        let favorites = FavoritesRepositoryStub()
        let window = try await signedInWindow(
            process: makeTestProcess(),
            writes: writes,
            favorites: favorites
        )
        defer { window.close() }
        window.favoriteFolderList.synchronize()
        await favorites.waitForFolderRequestCount(1)
        await waitForObservedState { !window.favoriteFolderList.folders.isEmpty }

        window.accountWrites.chooseFavoriteFolders(bvid: "BV17x411w7KC")
        let picker = try #require(window.accountWrites.favoritePicker)
        await waitForObservedState {
            if case .loaded = picker.phase { true } else { false }
        }
        #expect(picker.selectedFolderIDs == [10])
        picker.setSelected(false, folderID: 10)
        picker.setSelected(true, folderID: 20)
        window.accountWrites.confirmFavoritePicker()
        #expect(window.accountWrites.favoritePicker == nil)
        await waitForObservedState { window.accountWrites.report != nil }

        #expect(await writes.calls == ["favorite BV17x411w7KC +[20] -[10] 7"])
        #expect(window.accountWrites.report?.failure == nil)
        // 面板一次读取归属，成功后侧栏收藏夹在后台重读条数。
        await favorites.waitForFolderRequestCount(3)
    }

    /// 打开面板后换了账户：面板里的归属属于上一账户，确认时直接丢弃、不发请求；没有改动的确认同样不发请求。
    @Test
    func pickerConfirmationIsDroppedAfterAnAccountChange() async throws {
        let writes = AccountWriteRepositoryStub()
        let session = MutableWritableAccount()
        session.account = WritableAccount(accountID: 7, sessionGeneration: 1)
        let coordinator = standaloneCoordinator(writes: writes, session: session)
        defer { coordinator.close() }

        coordinator.chooseFavoriteFolders(bvid: "BV17x411w7KC")
        let picker = try #require(coordinator.favoritePicker)
        await waitForObservedState {
            if case .loaded = picker.phase { true } else { false }
        }
        coordinator.confirmFavoritePicker()

        coordinator.chooseFavoriteFolders(bvid: "BV17x411w7KC")
        let changed = try #require(coordinator.favoritePicker)
        await waitForObservedState {
            if case .loaded = changed.phase { true } else { false }
        }
        changed.setSelected(true, folderID: 20)
        session.account = WritableAccount(accountID: 8, sessionGeneration: 2)
        coordinator.confirmFavoritePicker()

        #expect(coordinator.favoritePicker == nil)
        #expect(await writes.calls.isEmpty)
        #expect(coordinator.report == nil)
    }

    /// 窗口账户变了（登出、换号、会话代次变化）：面板关闭；变化发生在读取失败之后时，重试也只关闭面板、不再读取。
    @Test
    func accountChangesClosePickerInsteadOfRereading() async throws {
        let favorites = FavoritesRepositoryStub(error: .unavailable)
        let session = MutableWritableAccount()
        session.account = WritableAccount(accountID: 7, sessionGeneration: 1)
        let coordinator = standaloneCoordinator(
            writes: AccountWriteRepositoryStub(),
            session: session,
            favorites: favorites
        )
        defer { coordinator.close() }

        coordinator.chooseFavoriteFolders(bvid: "BV17x411w7KC")
        let picker = try #require(coordinator.favoritePicker)
        await favorites.waitForFolderRequestCount(1)
        await waitForObservedState { picker.phase != .loading }
        coordinator.writableAccountDidChange()
        #expect(coordinator.favoritePicker === picker)

        session.account = WritableAccount(accountID: 7, sessionGeneration: 2)
        coordinator.retryFavoritePicker()
        #expect(coordinator.favoritePicker == nil)
        #expect(await favorites.folderOwnerIDs == [7])

        coordinator.chooseFavoriteFolders(bvid: "BV17x411w7KC")
        session.account = nil
        coordinator.writableAccountDidChange()
        #expect(coordinator.favoritePicker == nil)
    }

    /// 面板读取遇到凭据失效时请求一次窗口复核，与写入共用同一节流。
    @Test
    func pickerCredentialFailureRequestsOneRevalidation() async throws {
        let session = MutableWritableAccount()
        session.account = WritableAccount(accountID: 7, sessionGeneration: 1)
        let coordinator = standaloneCoordinator(
            writes: AccountWriteRepositoryStub(),
            session: session,
            favorites: FavoritesRepositoryStub(error: .authenticationInvalid)
        )
        defer { coordinator.close() }

        for _ in 0..<2 {
            coordinator.chooseFavoriteFolders(bvid: "BV17x411w7KC")
            let picker = try #require(coordinator.favoritePicker)
            await waitForObservedState { picker.phase != .loading }
        }

        #expect(coordinator.authenticationRevalidationGeneration == 1)
    }

    @Test
    func folderEntryRemovalIsOptimisticAndRollsBackOnFailure() async throws {
        let writes = AccountWriteRepositoryStub(outcomes: [.unavailable])
        let favorites = FavoritesRepositoryStub(
            pageItems: [
                favoriteItem("BV17x411w7KC", aid: 170_001), favoriteItem("BV1xx411c7mD", aid: 2)
            ]
        )
        let window = try await signedInWindow(
            process: makeTestProcess(),
            writes: writes,
            favorites: favorites
        )
        defer { window.close() }
        window.favoriteFolderList.synchronize()
        await waitForObservedState { !window.favoriteFolderList.folders.isEmpty }
        window.favoriteFolders.activate()
        await window.favoriteFolders.waitForCurrentTask()
        let entry = try #require(FavoriteFolderEntry(folderID: 10, videoAID: 170_001))

        #expect(window.favoriteFolders.totalCount == 2)
        window.accountWrites.removeFromFavoriteFolder(entry)
        #expect(window.favoriteFolders.totalCount == 1)
        await waitForObservedState { window.accountWrites.report != nil }

        #expect(window.favoriteFolders.totalCount == 2)
        #expect(window.accountWrites.report?.failure == .unavailable)
        #expect(await writes.calls == ["unfavorite 170001 from 10 7"])
    }

    /// 失败放回了标记，所以能再说一次；成功标上之后才能撤销。
    @Test
    func dislikeMarksTheCardAndRollsBackOnFailure() async throws {
        let writes = AccountWriteRepositoryStub(outcomes: [.restricted])
        let session = MutableWritableAccount()
        session.account = WritableAccount(accountID: 7, sessionGeneration: 1)
        let coordinator = standaloneCoordinator(
            writes: writes,
            session: session,
            browse: try await loadedRecommendations()
        )
        let feedback = try dislikeFeedback()

        coordinator.cancelRecommendationDislike(feedback)
        coordinator.dislikeRecommendation(feedback)
        await waitForObservedState { coordinator.report != nil }
        #expect(coordinator.report?.failure == .restricted)

        let failureSequence = coordinator.reportSequence
        coordinator.dislikeRecommendation(feedback)
        await waitForObservedState { coordinator.reportSequence != failureSequence }
        #expect(
            coordinator.report
                == AccountWriteReport(change: .recommendationDisliked(feedback), failure: nil)
        )

        let successSequence = coordinator.reportSequence
        coordinator.cancelRecommendationDislike(feedback)
        await waitForObservedState { coordinator.reportSequence != successSequence }
        #expect(
            await writes.calls == [
                "dislike BV17x411w7KC 1 7",
                "dislike BV17x411w7KC 1 7",
                "undislike BV17x411w7KC 1 7"
            ]
        )
    }

    @Test
    func oneFeedbackWritePerVideoAndOnlyForShownCards() async throws {
        let writes = AccountWriteRepositoryStub(holdsWrites: true)
        let session = MutableWritableAccount()
        session.account = WritableAccount(accountID: 7, sessionGeneration: 1)
        let coordinator = standaloneCoordinator(
            writes: writes,
            session: session,
            browse: try await loadedRecommendations()
        )
        let feedback = try dislikeFeedback()
        let notShownTarget = try #require(VideoWriteTarget(bvid: "BV1xx411c7mD"))
        let notShown = RecommendationFeedback(target: notShownTarget, reason: feedback.reason)

        coordinator.dislikeRecommendation(notShown)
        coordinator.dislikeRecommendation(feedback)
        await writes.waitForCallCount(1)
        coordinator.cancelRecommendationDislike(feedback)
        await writes.releaseWrites()
        await waitForObservedState { coordinator.report != nil }

        #expect(await writes.calls == ["dislike BV17x411w7KC 1 7"])
    }

    /// 撤销途中换了账户，新推荐恰好有同一视频：撤销失败也不把旧账户的反馈标到新推荐上。
    @Test
    func failedUndoDoesNotMarkTheNextAccountsRecommendations() async throws {
        let writes = AccountWriteRepositoryStub(outcomes: [.restricted], holdsWrites: true)
        let session = MutableWritableAccount()
        session.account = WritableAccount(accountID: 7, sessionGeneration: 1)
        let browse = try await loadedRecommendations()
        let coordinator = standaloneCoordinator(writes: writes, session: session, browse: browse)
        let feedback = try dislikeFeedback()
        #expect(browse.markRecommendationDisliked(feedback) != nil)

        coordinator.cancelRecommendationDislike(feedback)
        await writes.waitForCallCount(1)
        browse.synchronizeAuthenticationSession(generation: 2)
        await browse.waitForCurrentTask()
        await writes.releaseWrites()
        await waitForObservedState { coordinator.report != nil }

        #expect(coordinator.report?.failure == .restricted)
        #expect(browse.unmarkRecommendationDisliked(feedback) == nil)
        #expect(browse.markRecommendationDisliked(feedback) != nil)
    }

    private func loadedRecommendations() async throws -> BrowseViewModel {
        let video = RecommendedVideo(
            bvid: "BV17x411w7KC",
            title: "推荐",
            coverURL: nil,
            owner: VideoOwner(id: 1, name: "作者"),
            viewCount: 1,
            danmakuCount: 0,
            durationSeconds: 60,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            recommendationReason: nil,
            dislikeReasons: [try #require(RecommendationDislikeReason(id: 1, name: "这个内容"))]
        )
        let browse = BrowseViewModel(
            useCase: FeedUseCase(repository: FeedRepositoryStub(recommendations: [video]))
        )
        await browse.activate(.recommendation)
        return browse
    }

    private func dislikeFeedback() throws -> RecommendationFeedback {
        RecommendationFeedback(
            target: try target(),
            reason: try #require(RecommendationDislikeReason(id: 1, name: "这个内容"))
        )
    }

    private func standaloneCoordinator(
        writes: AccountWriteRepositoryStub,
        session: MutableWritableAccount,
        favorites: FavoritesRepositoryStub = FavoritesRepositoryStub(),
        browse: BrowseViewModel = BrowseViewModel(
            useCase: FeedUseCase(repository: FeedRepositoryStub())
        )
    ) -> AccountWriteCoordinator {
        let favoritesUseCase = FavoritesUseCase(repository: favorites)
        let engagementUseCase = VideoEngagementUseCase(repository: writes)
        return AccountWriteCoordinator(
            watchLater: WatchLaterWriteUseCase(repository: writes),
            watchLaterModel: WatchLaterViewModel(
                useCase: WatchLaterUseCase(repository: WatchLaterRepositoryStub())
            ),
            favoritesWrite: FavoritesWriteUseCase(repository: writes),
            favorites: favoritesUseCase,
            favoriteFolders: FavoriteFolderViewModel(
                useCase: favoritesUseCase,
                folderList: FavoriteFolderListModel(
                    useCase: favoritesUseCase,
                    accountScope: { .signedOut }
                )
            ),
            engagement: engagementUseCase,
            engagementModel: VideoEngagementModel(
                useCase: engagementUseCase,
                accountID: { session.account?.accountID }
            ),
            recommendationFeedback: RecommendationFeedbackUseCase(repository: writes),
            danmakuPost: DanmakuPostUseCase(repository: writes),
            commentWrite: CommentWriteUseCase(repository: writes),
            browseModel: browse,
            writableAccount: { session.account },
            publish: { _, _ in }
        )
    }

    @Test
    func danmakuPostsOneAtATimeAndReportsOnlyToTheComposer() async throws {
        let writes = AccountWriteRepositoryStub(holdsWrites: true)
        let window = try await signedInWindow(process: makeTestProcess(), writes: writes)
        defer { window.close() }
        let outcomes = DanmakuOutcomeRecorder()
        let request = try danmakuRequest()

        #expect(window.accountWrites.postDanmaku(request, completion: outcomes.record))
        #expect(!window.accountWrites.postDanmaku(request, completion: outcomes.record))
        await writes.waitForCallCount(1)
        await writes.releaseWrites()
        await waitForObservedState { !outcomes.values.isEmpty }

        #expect(outcomes.values == [.posted(DanmakuPostReceipt(danmakuID: "dm-1"))])
        #expect(await writes.calls == ["danmaku BV17x411w7KC 好 7"])
        #expect(window.accountWrites.report == nil)
    }

    @Test
    func closingTheWindowCancelsTheDanmakuInFlight() async throws {
        let writes = AccountWriteRepositoryStub(holdsWrites: true)
        let window = try await signedInWindow(process: makeTestProcess(), writes: writes)
        let outcomes = DanmakuOutcomeRecorder()

        window.accountWrites.postDanmaku(try danmakuRequest(), completion: outcomes.record)
        await writes.waitForCallCount(1)
        window.close()
        await writes.releaseWrites()
        await waitForObservedState { !outcomes.values.isEmpty }

        #expect(outcomes.values == [.cancelled])
        let request = try danmakuRequest()
        #expect(!window.accountWrites.postDanmaku(request, completion: outcomes.record))
    }

    @Test
    func likeIsOptimisticAndRollsBackOnFailure() async throws {
        let writes = AccountWriteRepositoryStub(outcomes: [.restricted])
        let window = try await signedInWindow(process: makeTestProcess(), writes: writes)
        defer { window.close() }
        await presentEngagement(in: window)

        window.accountWrites.setLiked(true, bvid: "BV17x411w7KC")
        #expect(window.engagementModel.engagement?.isLiked == true)
        await waitForObservedState { window.accountWrites.report != nil }

        #expect(window.engagementModel.engagement?.isLiked == false)
        #expect(window.accountWrites.report?.failure == .restricted)
        #expect(await writes.calls == ["like BV17x411w7KC 7"])
    }

    /// 反方向的点赞还在途时不发：两个请求到达服务端的顺序不可知。
    @Test
    func oppositeLikeWaitsForTheInFlightOne() async throws {
        let writes = AccountWriteRepositoryStub(holdsWrites: true)
        let window = try await signedInWindow(process: makeTestProcess(), writes: writes)
        defer { window.close() }
        await presentEngagement(in: window)

        window.accountWrites.setLiked(true, bvid: "BV17x411w7KC")
        await writes.waitForCallCount(1)
        window.accountWrites.setLiked(false, bvid: "BV17x411w7KC")
        await writes.releaseWrites()
        await waitForObservedState { window.accountWrites.report != nil }

        #expect(await writes.calls == ["like BV17x411w7KC 7"])
        #expect(window.engagementModel.engagement?.isLiked == true)
    }

    @Test
    func coinsAndTripleApplyOnSuccessAndTripleRefreshesFavorites() async throws {
        let writes = AccountWriteRepositoryStub(
            tripleOutcome: VideoTripleOutcome(
                isLiked: true,
                isCoined: true,
                isFavorited: true,
                addedCoinCount: 1
            )
        )
        let favorites = FavoritesRepositoryStub()
        let window = try await signedInWindow(
            process: makeTestProcess(),
            writes: writes,
            favorites: favorites
        )
        defer { window.close() }
        window.favoriteFolderList.synchronize()
        await favorites.waitForFolderRequestCount(1)
        await waitForObservedState { !window.favoriteFolderList.folders.isEmpty }
        await presentEngagement(in: window)

        window.accountWrites.addCoins(1, alsoLike: true, bvid: "BV17x411w7KC")
        #expect(window.engagementModel.engagement?.coinCount == 0)
        await waitForObservedState { window.accountWrites.report != nil }
        #expect(
            window.engagementModel.engagement
                == VideoEngagementState(isLiked: true, coinCount: 1, isFavorited: false)
        )

        let sequence = window.accountWrites.reportSequence
        window.accountWrites.triple(bvid: "BV17x411w7KC")
        await waitForObservedState { window.accountWrites.reportSequence != sequence }

        #expect(
            window.engagementModel.engagement
                == VideoEngagementState(isLiked: true, coinCount: 2, isFavorited: true)
        )
        #expect(await writes.calls == ["coin 1 +like BV17x411w7KC 7", "triple BV17x411w7KC 7"])
        // 三连的收藏进默认收藏夹：侧栏收藏夹在后台重读条数。
        await favorites.waitForFolderRequestCount(2)
    }

    @Test
    func shortcutsExplainWhyTheyCannotAct() async throws {
        let signedOut = WindowComposition(process: makeTestProcess(), adapters: makeTestAdapters())
        signedOut.authenticationModel.restoreIfNeeded()
        await signedOut.authenticationModel.waitForCurrentTask()
        defer { signedOut.close() }
        let signedOutShortcuts = PlayerEngagementShortcuts.make(
            accountWrites: signedOut.accountWrites,
            engagementModel: signedOut.engagementModel,
            videoModel: signedOut.videoModel
        )
        #expect(signedOutShortcuts.toggleLike() == .signInRequired)

        let fixture = VideoFixture(bvid: "BV17x411w7KC")
        let window = try await signedInWindow(
            process: makeTestProcess(),
            video: FixtureVideoRepository(fixtures: [fixture])
        )
        defer { window.close() }
        let shortcuts = PlayerEngagementShortcuts.make(
            accountWrites: window.accountWrites,
            engagementModel: window.engagementModel,
            videoModel: window.videoModel
        )
        // 播放页还没有展示这个视频：不响应。
        await presentEngagement(in: window)
        #expect(shortcuts.triple() == .unavailable)

        window.videoModel.loadVideo(fixture.bvid)
        await waitForObservedState {
            window.videoModel.presentedBVID == fixture.bvid
                && !window.videoModel.blocksPresentedContext
        }
        #expect(shortcuts.openCoinPanel(true) == .exitFullScreenToCoin)
        #expect(!window.engagementModel.isCoinPanelPresented)
        #expect(shortcuts.openCoinPanel(false) == nil)
        #expect(window.engagementModel.isCoinPanelPresented)
        #expect(shortcuts.chooseFavoriteFolders(true) == .exitFullScreenToFavorite)
        #expect(window.accountWrites.favoritePicker == nil)
        #expect(shortcuts.chooseFavoriteFolders(false) == nil)
        #expect(window.accountWrites.favoritePicker != nil)
        #expect(shortcuts.toggleLike() == .liked)
    }

    /// 同一视频的点赞、投币、三连同时只发一个；投币不超过此刻的可投数。
    @Test
    func oneEngagementWritePerVideoAndCoinsWithinTheRemainder() async throws {
        let writes = AccountWriteRepositoryStub(holdsWrites: true)
        let window = try await signedInWindow(process: makeTestProcess(), writes: writes)
        defer { window.close() }
        await presentEngagement(in: window)

        #expect(window.accountWrites.triple(bvid: "BV17x411w7KC"))
        await writes.waitForCallCount(1)
        #expect(!window.accountWrites.setLiked(true, bvid: "BV17x411w7KC"))
        #expect(!window.accountWrites.addCoins(1, alsoLike: false, bvid: "BV17x411w7KC"))
        await writes.releaseWrites()
        await waitForObservedState { window.accountWrites.report != nil }

        #expect(window.engagementModel.remainingCoins == 0)
        #expect(!window.accountWrites.addCoins(1, alsoLike: false, bvid: "BV17x411w7KC"))
        #expect(await writes.calls == ["triple BV17x411w7KC 7"])
    }

    private func load(_ model: WatchLaterViewModel) async {
        model.loadIfNeeded()
        await model.waitForCurrentTask()
    }

    private func bvids(_ model: WatchLaterViewModel) -> [String] {
        guard case .loaded(let items, _, _) = model.state else { return [] }
        return items.map(\.bvid)
    }

    private func favoriteItem(_ bvid: String, aid: Int64) -> FavoriteItem {
        FavoriteItem(
            id: bvid,
            title: bvid,
            coverURL: nil,
            owner: VideoOwner(id: 1, name: "作者"),
            durationSeconds: 60,
            favoritedAt: Date(timeIntervalSince1970: 1_700_000_000),
            videoAID: aid
        )
    }

    private func target() throws -> VideoWriteTarget {
        try #require(VideoWriteTarget(bvid: "BV17x411w7KC"))
    }

    private func danmakuRequest() throws -> DanmakuPostRequest {
        try #require(
            DanmakuPostUseCase.request(
                text: "好",
                identity: PlaybackItemIdentity(bvid: "BV17x411w7KC", cid: 1),
                positionSeconds: 1
            )
        )
    }
}

/// 记录写入协调者交回输入胶囊的弹幕结局。
@MainActor
@Observable
private final class DanmakuOutcomeRecorder {
    private(set) var values: [DanmakuPostOutcome] = []

    func record(_ outcome: DanmakuPostOutcome) {
        values.append(outcome)
    }
}

/// 测试里可变的窗口写入账户；门槛闭包在主线程读取。
@MainActor
private final class MutableWritableAccount {
    var account: WritableAccount?
}
