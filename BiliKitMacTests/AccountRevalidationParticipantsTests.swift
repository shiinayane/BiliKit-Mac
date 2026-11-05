import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import BiliVideoDetailFeature
import Testing

@testable import BiliKit

/// 窗口复核汇总：任一参与者的代次变化（含回绕）都请求一次复核，复核结果只交给不绑定来源或绑定当前来源的参与者。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AccountRevalidationParticipantsTests {
    @Test
    func anyParticipantGenerationChangeRequestsOneRevalidation() {
        let first = RecordingRevalidationParticipant()
        let second = RecordingRevalidationParticipant()
        let participants = AccountRevalidationParticipants(
            entries: [
                .init(participant: first, route: nil), .init(participant: second, route: .history)
            ]
        )
        let initial = participants.generations

        #expect(!AccountRevalidationParticipants.requestsRevalidation(from: initial, to: initial))
        second.authenticationRevalidationGeneration &+= 1
        let afterSecond = participants.generations
        #expect(afterSecond == [0, 1])
        #expect(
            AccountRevalidationParticipants.requestsRevalidation(from: initial, to: afterSecond)
        )

        first.authenticationRevalidationGeneration = .max
        let beforeWrap = participants.generations
        first.authenticationRevalidationGeneration &+= 1
        #expect(
            AccountRevalidationParticipants.requestsRevalidation(
                from: beforeWrap,
                to: participants.generations
            )
        )
    }

    @Test(arguments: AppTab.allCases)
    func revalidationResultReachesRouteBoundParticipantsOnlyOnTheirRoute(currentRoute: AppTab) {
        let windowWide = RecordingRevalidationParticipant()
        let history = RecordingRevalidationParticipant()
        let participants = AccountRevalidationParticipants(
            entries: [
                .init(participant: windowWide, route: nil),
                .init(participant: history, route: .history)
            ]
        )

        participants.finishRevalidation(.signedIn, currentRoute: currentRoute)
        participants.finishRevalidation(.signedOut, currentRoute: currentRoute)
        participants.finishRevalidation(.failed, currentRoute: currentRoute)
        participants.finishRevalidation(.other, currentRoute: currentRoute)

        let delivered = ["succeeded", "signedOut", "failed"]
        #expect(windowWide.events == delivered)
        #expect(history.events == (currentRoute == .history ? delivered : []))
    }

    /// 窗口组装登记了全部九个参与者，只有稍后再看、观看历史与收藏夹的夹内页面绑定来源，收藏夹列表是窗口级；漏登记会让
    /// 那一页的凭据失效静默不复核。
    @Test
    func windowCompositionRegistersEveryParticipant() {
        let owner = WindowComposition(process: makeTestProcess(), adapters: makeTestAdapters())
        let expected: [(AnyObject, AppTab?)] = [
            (owner.videoModel, nil),
            (owner.browseModel, nil),
            (owner.danmakuModel, nil),
            (owner.commentsModel, nil),
            (owner.navigationCoordinator.uploaderSpace, nil),
            (owner.favoriteFolderList, nil),
            (owner.accountWrites, nil),
            (owner.engagementModel, nil),
            (owner.watchLaterModel, .watchLater),
            (owner.historyModel, .history),
            (owner.favoriteFolders, .favorites)
        ]
        let entries = owner.revalidationParticipants.entries

        #expect(entries.count == expected.count)
        for (participant, route) in expected {
            #expect(entries.contains { $0.participant === participant && $0.route == route })
        }
    }

    /// 观看历史没有请求复核时，不在历史页的复核成功也不能让它在后台加载。
    @Test
    func historyDoesNotLoadWhenRevalidationEndsElsewhere() async {
        let historyModel = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: WatchHistoryRepositoryStub())
        )
        let participants = AccountRevalidationParticipants(
            entries: [.init(participant: historyModel, route: .history)]
        )

        participants.finishRevalidation(.signedIn, currentRoute: .home)
        await historyModel.waitForCurrentTask()
        #expect(historyModel.state == .idle)

        participants.finishRevalidation(.signedIn, currentRoute: .history)
        await historyModel.waitForCurrentTask()
        #expect(historyModel.successfulReloadGeneration == 1)
    }
}

/// 复核参与者的可设代次替身，记录收到的复核结果。
@MainActor
private final class RecordingRevalidationParticipant: AccountRevalidationParticipant {
    var authenticationRevalidationGeneration = 0
    private(set) var events: [String] = []

    func authenticationRevalidationSucceeded() {
        events.append("succeeded")
    }

    func authenticationRevalidationConfirmedSignedOut() {
        events.append("signedOut")
    }

    func authenticationRevalidationFailed() {
        events.append("failed")
    }
}
