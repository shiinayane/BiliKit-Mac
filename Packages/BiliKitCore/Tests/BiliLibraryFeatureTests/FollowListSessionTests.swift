import BiliApplication
import BiliModels
import Testing

@testable import BiliLibraryFeature

/// 关注页的条件到请求，以及侧栏分组读取的失败隔离。
///
/// 全部关注按排序读、提交关键词后按搜索读；换到分组读这个分组并清掉关键词；分组重读后选中的分组不在了就回到全部关注，
/// 在本页时立即重读，不在本页时只改选择、回来再读。窗口账户还没确认时不读、也不当成凭据失败。总人数读不到时分组照常、
/// 只缺人数。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct FollowListSessionTests {
    private let special = FollowGroup(id: FollowGroup.specialID, name: "特别关注", count: 1)
    private let custom = FollowGroup(id: 5, name: "游戏", count: 2)
    private let defaultGroup = FollowGroup(id: FollowGroup.defaultID, name: "默认分组", count: 9)

    @Test
    func conditionsMapToTheirRequests() async {
        let repository = FollowListRepositoryStub()
        let (session, _) = makeSession(repository)

        session.model.loadIfNeeded()
        await session.model.waitForCurrentTask()
        session.selectOrder(.mostVisited)
        await session.model.waitForCurrentTask()
        session.searchDraft = "  极客 "
        session.submitSearch()
        await session.model.waitForCurrentTask()
        session.select(rowID: custom.id)
        await session.model.waitForCurrentTask()

        #expect(
            await repository.requestedCursors == [
                FollowListCursor(query: .all(.recentlyFollowed)),
                FollowListCursor(query: .all(.mostVisited)),
                FollowListCursor(query: .search("极客")),
                FollowListCursor(query: .group(5))
            ]
        )
        #expect(session.appliedKeyword.isEmpty)
        #expect(session.order == .mostVisited)
    }

    /// 在网页上删了正在看的分组：分组列表重读后回到全部关注。
    ///
    /// 在本页时立即读全部关注；不在本页时只改选择、丢弃旧分组的内容，不在后台读，回到本页才读。
    @Test(arguments: [true, false])
    func aSelectedGroupThatDisappearsFallsBackToAllFollowings(isOnPage: Bool) async {
        let repository = FollowListRepositoryStub(groups: [special, custom, defaultGroup])
        let (session, groupList) = makeSession(repository)
        groupList.synchronize()
        await waitForObservedState { groupList.loadedValue != nil }
        session.activate()
        session.select(rowID: custom.id)
        await session.model.waitForCurrentTask()
        if !isOnPage { session.deactivateRoute() }
        let requestsBeforeFallback = await repository.requestedCursors.count

        await repository.replaceGroups([special, defaultGroup])
        groupList.reload()
        await waitForObservedState { groupList.groups.count == 2 }
        await session.model.waitForCurrentTask()

        let allFollowings = FollowListCursor(query: .all(.recentlyFollowed))
        #expect(session.selectedRowID == FollowListSession.allFollowingsRowID)
        if isOnPage {
            #expect(await repository.requestedCursors.last == allFollowings)
        } else {
            #expect(await repository.requestedCursors.count == requestsBeforeFallback)
            #expect(session.model.state == .idle)
            session.activate()
            await session.model.waitForCurrentTask()
            #expect(await repository.requestedCursors.last == allFollowings)
        }
    }

    /// 认证仍在确认或其他窗口换号、本窗口还没复核到：不用旧账户的 mid 去读，回到未加载，不显示失败也不请求复核。
    @Test
    func anUnresolvedAccountReadsNothingAndStaysIdle() async {
        let repository = FollowListRepositoryStub()
        let (session, _) = makeSession(repository, accountID: { nil })

        session.activate()
        await session.model.waitForCurrentTask()

        #expect(await repository.requestedCursors.isEmpty)
        #expect(session.model.state == .idle)
        #expect(session.model.authenticationRevalidationGeneration == 0)
    }

    @Test
    func sidebarGroupsStillLoadWhenTheTotalCountFails() async {
        let repository = FollowListRepositoryStub(
            groups: [special, defaultGroup, custom],
            totalCount: .failure(.transportFailure)
        )
        let (_, groupList) = makeSession(repository)

        groupList.synchronize()
        await waitForObservedState { groupList.loadedValue != nil }

        #expect(Set(groupList.groups.map(\.id)) == [special.id, custom.id, defaultGroup.id])
        #expect(groupList.loadedValue?.totalCount == nil)
    }

    private func makeSession(
        _ repository: FollowListRepositoryStub,
        accountID: @escaping @MainActor () -> Int64? = { 7 }
    ) -> (FollowListSession, FollowGroupListModel) {
        let useCase = FollowListUseCase(repository: repository)
        let groupList = FollowGroupListModel(
            useCase: useCase,
            accountScope: { .signedIn(accountID: 7) }
        )
        let session = FollowListSession(
            model: FollowListViewModel(useCase: useCase, accountID: accountID, reconcile: { $2 }),
            groupList: groupList
        )
        return (session, groupList)
    }
}
