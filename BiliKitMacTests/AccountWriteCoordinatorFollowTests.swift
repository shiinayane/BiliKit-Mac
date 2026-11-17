import BiliApplication
import BiliLibraryFeature
import BiliModels
import BiliVideoDetailFeature
import Foundation
import Testing

@testable import BiliKit

/// 关注关系的写入：特别关注、设置分组与关注页卡片的取消关注只对确认已关注的人发出，同一个人的关注、取消关注、特别关注与
/// 设置分组（含播放页与空间页的入口）同时只有一个在途；乐观改动只在关系存储或关注页列表里，失败放回；成功的效果带写前与
/// 写后的分组，每个窗口按它在本地改侧栏人数（只加入特别关注时默认分组随之减一）、去掉已不属于当前列表的卡片、关系存储取
/// 确认值；「设置分组…」每次打开都读一次单人关系作底、没改不提交、同一个人的写入在途时不能提交，窗口账户一变或这个人
/// 已经没有关注时关闭；关注页的一页只记在读取它的账户名下。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AccountWriteCoordinatorFollowTests {
    private static let bvid = "BV17x411w7KC"
    /// 甲（mid 1）在自定义分组 5，丙（mid 3）只在默认分组。
    private static let inGroupFive = FollowMembership(isSpecial: false, customGroupIDs: [5])
    private static let users = [
        FollowedUser(id: 1, name: "甲", membership: inGroupFive),
        FollowedUser(id: 3, name: "丙", membership: .defaultGroupOnly)
    ]
    private static let groups = [
        FollowGroup(id: FollowGroup.specialID, name: "特别关注", count: 1),
        FollowGroup(id: 5, name: "同学", count: 2),
        FollowGroup(id: FollowGroup.defaultID, name: "默认分组", count: 3)
    ]

    @Test
    func specialWriteAdjustsCountsAndEveryWindowTakesTheConfirmedRelation() async throws {
        let process = makeTestProcess()
        let writes = AccountWriteRepositoryStub()
        let origin = try await followWindow(process: process, writes: writes)
        let other = try await followWindow(process: process)
        defer {
            origin.close()
            other.close()
        }

        #expect(origin.accountWrites.setFollowSpecial(true, mid: 3))
        #expect(origin.followRelations.specialState(of: 3) == true)
        await waitForObservedState { origin.accountWrites.report != nil }

        let target = try #require(UploaderWriteTarget(mid: 3))
        #expect(
            origin.accountWrites.report
                == AccountWriteReport(
                    change: .followSpecialChanged(
                        target,
                        isSpecial: true,
                        before: .defaultGroupOnly
                    ),
                    failure: nil
                )
        )
        let special = FollowMembership(isSpecial: true, customGroupIDs: [])
        for window in [origin, other] {
            #expect(counts(window) == [FollowGroup.specialID: 2, 5: 2, FollowGroup.defaultID: 2])
            #expect(window.followGroupList.loadedValue?.totalCount == 6)
            #expect(window.followRelations.relation(of: 3) == .following(special))
        }
        #expect(await writes.calls == ["special 3 7"])
    }

    @Test
    func failedWritesRollBackAndUnknownOrUnchangedRelationsSendNothing() async throws {
        let writes = AccountWriteRepositoryStub(outcomes: [.restricted])
        let window = try await followWindow(process: makeTestProcess(), writes: writes)
        defer { window.close() }

        #expect(window.accountWrites.setFollowSpecial(true, mid: 3))
        await waitForObservedState { window.accountWrites.report != nil }
        #expect(window.followRelations.specialState(of: 3) == false)
        #expect(counts(window) == [FollowGroup.specialID: 1, 5: 2, FollowGroup.defaultID: 3])

        // 99 不在关注页里、关系未知；丙已经不在特别关注。
        #expect(!window.accountWrites.setFollowSpecial(true, mid: 99))
        #expect(!window.accountWrites.assignFollowGroups(Self.inGroupFive, mid: 99))
        #expect(!window.accountWrites.unfollow(mid: 99))
        window.accountWrites.chooseFollowGroups(mid: 99)
        #expect(window.accountWrites.followGroupPicker == nil)
        #expect(!window.accountWrites.setFollowSpecial(false, mid: 3))
        #expect(await writes.calls == ["special 3 7"])
    }

    /// 同一个人只有一个关系写入在途，播放页与空间页的关注按钮也被挡住；别人的写入照常，「设置分组…」在途时不能提交。
    @Test
    func relationWritesForOnePersonAreExclusiveAcrossEveryEntry() async throws {
        let writes = AccountWriteRepositoryStub(
            holdsWrites: true,
            engagement: VideoEngagementState(
                isLiked: false,
                coinCount: 0,
                isFavorited: false,
                isFollowingUploader: true
            )
        )
        let window = try await followWindow(
            process: makeTestProcess(),
            writes: writes,
            uploaderProfile: UploaderProfileRepositoryStub(
                holdsRequests: false,
                viewerFollows: true
            )
        )
        defer { window.close() }
        await presentEngagement(in: window)
        window.navigationCoordinator.openUploaderSpacePage(owner: VideoOwner(id: 1, name: "甲"))
        let page = window.navigationCoordinator.uploaderSpacePage
        await waitForObservedState { page.viewerFollows != nil }

        #expect(window.accountWrites.setFollowSpecial(true, mid: 1))
        await writes.waitForCallCount(1)
        #expect(!window.accountWrites.setFollowing(false, bvid: Self.bvid))
        #expect(!window.accountWrites.setFollowing(false, onSpacePage: page))
        #expect(!window.accountWrites.unfollow(mid: 1))
        #expect(!window.accountWrites.assignFollowGroups(.defaultGroupOnly, mid: 1))
        window.accountWrites.chooseFollowGroups(mid: 1)
        let picker = try #require(window.accountWrites.followGroupPicker)
        #expect(picker.isBlockedByWriteInFlight)
        #expect(window.accountWrites.setFollowSpecial(true, mid: 3))

        await writes.releaseWrites()
        await waitForObservedState { !picker.isBlockedByWriteInFlight }
        await waitForObservedState { !window.accountWrites.hasRelationWriteInFlight(mid: 3) }
        #expect(Set(await writes.calls) == ["special 1 7", "special 3 7"])
    }

    @Test
    func cardUnfollowIsOptimisticAndCountsComeFromTheKnownGroups() async throws {
        let process = makeTestProcess()
        let writes = AccountWriteRepositoryStub(outcomes: [.restricted])
        let origin = try await followWindow(process: process, writes: writes)
        let other = try await followWindow(process: process)
        defer {
            origin.close()
            other.close()
        }

        #expect(origin.accountWrites.unfollow(mid: 1))
        #expect(listedIDs(origin) == [3])
        await waitForObservedState { origin.accountWrites.report != nil }
        #expect(listedIDs(origin) == [1, 3])

        let sequence = origin.accountWrites.reportSequence
        #expect(origin.accountWrites.unfollow(mid: 1))
        await waitForObservedState { origin.accountWrites.reportSequence != sequence }

        for window in [origin, other] {
            #expect(listedIDs(window) == [3])
            #expect(counts(window) == [FollowGroup.specialID: 1, 5: 1, FollowGroup.defaultID: 3])
            #expect(window.followGroupList.loadedValue?.totalCount == 5)
            #expect(window.followRelations.relation(of: 1) == .notFollowing)
        }
        #expect(await writes.calls == ["unfollow 1 7", "unfollow 1 7"])
    }

    /// 每次打开都读一次单人关系作底（关注页那一页可能已经过时），读到之前不能提交；没改不提交；提交的是完整集合，成功后
    /// 人数按前后差异调整。
    @Test
    func groupPickerSubmitsTheWholeSetOnlyWhenItChanged() async throws {
        let writes = AccountWriteRepositoryStub()
        let follows = makeFollowList()
        let window = try await followWindow(
            process: makeTestProcess(),
            writes: writes,
            followList: follows
        )
        defer { window.close() }

        window.accountWrites.chooseFollowGroups(mid: 3)
        window.accountWrites.confirmFollowGroupPicker()
        window.accountWrites.chooseFollowGroups(mid: 1)
        let picker = try #require(window.accountWrites.followGroupPicker)
        #expect(picker.phase == .loading)
        #expect(picker.submission == nil)
        await waitForObservedState { picker.phase == .loaded(Self.inGroupFive) }
        let special = try #require(picker.rows.first)
        picker.setSelected(true, row: special)
        window.accountWrites.confirmFollowGroupPicker()
        await waitForObservedState { window.accountWrites.report != nil }
        // 两次打开各发一次单人关系读取，各自经非隔离的用例到达替身，先后不定；丙那次的面板已关，读取仍会落地。
        await waitForObservedState { window.followRelations.readPhase(of: 3) == nil }

        #expect(window.accountWrites.followGroupPicker == nil)
        #expect(await writes.calls == ["groups 1 [-10, 5] 7"])
        #expect(await follows.relationReads.sorted() == [1, 3])
        #expect(counts(window) == [FollowGroup.specialID: 2, 5: 2, FollowGroup.defaultID: 3])
    }

    /// 面板打开期间读到这个人已经没有关注（在网页上取消了）：关闭面板，不停在“无法读取”。
    @Test
    func groupPickerClosesWhenThePersonTurnsOutNotFollowed() async throws {
        let follows = FollowListRepositoryStub(
            groups: Self.groups,
            totalCount: 6,
            users: Self.users,
            relations: [1: Self.inGroupFive]
        )
        let window = try await followWindow(process: makeTestProcess(), followList: follows)
        defer { window.close() }

        window.accountWrites.chooseFollowGroups(mid: 3)
        #expect(window.accountWrites.followGroupPicker != nil)
        await waitForObservedState { window.accountWrites.followGroupPicker == nil }

        #expect(window.followRelations.relation(of: 3) == .notFollowing)
    }

    /// 关注按钮只在没有关注时发出关注，写前就是没有关注：存储里此前读到的“已关注”（读取与写入赛跑时）不能让人数少加一。
    @Test
    func followingFromTheButtonAlwaysCountsFromNotFollowing() async throws {
        let window = try await followWindow(
            process: makeTestProcess(),
            uploaderProfile: UploaderProfileRepositoryStub(
                holdsRequests: false,
                viewerFollows: false
            )
        )
        defer { window.close() }
        window.navigationCoordinator.openUploaderSpacePage(owner: VideoOwner(id: 3, name: "丙"))
        let page = window.navigationCoordinator.uploaderSpacePage
        await waitForObservedState { page.viewerFollows != nil }
        #expect(window.followRelations.relation(of: 3) == .following(.defaultGroupOnly))

        #expect(window.accountWrites.setFollowing(true, onSpacePage: page))
        await waitForObservedState { window.accountWrites.report != nil }

        #expect(counts(window) == [FollowGroup.specialID: 1, 5: 2, FollowGroup.defaultID: 4])
        #expect(window.followGroupList.loadedValue?.totalCount == 7)
    }

    /// 关注页的一页只记在读取它的账户名下：请求途中窗口换了号，迟到的页不能把上一账户的关系记给新账户。
    @Test
    func aPageReadForAnotherAccountIsNotRecorded() {
        let follows = FollowWriteDependencies(
            writableAccount: { WritableAccount(accountID: 7, sessionGeneration: 1) }
        )

        _ = follows.relations.reconcile(Self.users, in: .all(.recentlyFollowed), ownerID: 8)
        #expect(follows.relations.relation(of: 1) == nil)

        _ = follows.relations.reconcile(Self.users, in: .all(.recentlyFollowed), ownerID: 7)
        #expect(follows.relations.relation(of: 1) == .following(Self.inGroupFive))
    }

    @Test
    func groupPickerClosesWhenTheWindowAccountChanges() async throws {
        let process = makeTestProcess()
        let window = try await followWindow(process: process)
        defer { window.close() }

        window.accountWrites.chooseFollowGroups(mid: 1)
        #expect(window.accountWrites.followGroupPicker != nil)
        // 其他窗口换了号、本窗口还没复核：写入账户变为未知。
        process.accountSession.publish(.signedIn(accountID: 8))
        window.accountWrites.writableAccountDidChange()

        #expect(window.accountWrites.followGroupPicker == nil)
        #expect(window.followRelations.relation(of: 1) == nil)
    }

    /// 已登录（mid 7）、侧栏分组与关注页第一页都已读到的窗口。
    private func followWindow(
        process: ProcessComposition,
        writes: AccountWriteRepositoryStub = AccountWriteRepositoryStub(),
        followList: FollowListRepositoryStub? = nil,
        uploaderProfile: any UploaderProfileRepository = UploaderProfileRepositoryStub(
            holdsRequests: true
        )
    ) async throws -> WindowComposition {
        let window = try await signedInWindow(
            process: process,
            writes: writes,
            followList: followList ?? makeFollowList(),
            uploaderProfile: uploaderProfile
        )
        window.followGroupList.synchronize()
        await waitForObservedState { window.followGroupList.loadedValue != nil }
        window.followSession.model.loadIfNeeded()
        await window.followSession.model.waitForCurrentTask()
        return window
    }

    private func makeFollowList() -> FollowListRepositoryStub {
        FollowListRepositoryStub(
            groups: Self.groups,
            totalCount: 6,
            users: Self.users,
            relations: [1: Self.inGroupFive, 3: .defaultGroupOnly]
        )
    }

    private func counts(_ window: WindowComposition) -> [Int64: Int] {
        Dictionary(uniqueKeysWithValues: window.followGroupList.groups.map { ($0.id, $0.count) })
    }

    private func listedIDs(_ window: WindowComposition) -> [Int64] {
        if case .loaded(let users, _, _) = window.followSession.model.state {
            users.map(\.id)
        } else {
            []
        }
    }
}
