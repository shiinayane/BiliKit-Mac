import BiliApplication
import BiliLibraryFeature
import BiliModels

@testable import BiliKit

/// 本 target 的 `FollowListRepository` 替身：给出固定的分组、总人数、每页结果与按 mid 的单人关系，并记录请求过的游标、
/// 分组读取次数与单人关系读取。
actor FollowListRepositoryStub: FollowListRepository {
    private let groups: [FollowGroup]
    private let totalCount: Int
    private let users: [FollowedUser]
    private let relations: [Int64: FollowMembership]
    private(set) var requestedCursors: [FollowListCursor] = []
    private(set) var groupReadCount = 0
    private(set) var relationReads: [Int64] = []
    private var groupReadWaiters = CountWaiters()

    /// `relations` 里没有的 mid 按没有关注（nil）返回。
    init(
        groups: [FollowGroup] = [],
        totalCount: Int = 0,
        users: [FollowedUser] = [],
        relations: [Int64: FollowMembership] = [:]
    ) {
        self.groups = groups
        self.totalCount = totalCount
        self.users = users
        self.relations = relations
    }

    func groups(ownerID: Int64) async throws -> [FollowGroup] {
        groupReadCount += 1
        groupReadWaiters.resume(reaching: groupReadCount)
        return groups
    }

    func followingCount(ownerID: Int64) async throws -> Int { totalCount }

    func page(
        _ cursor: FollowListCursor,
        ownerID: Int64,
        pageSize: Int
    ) async throws -> FollowListRemotePage {
        requestedCursors.append(cursor)
        return FollowListRemotePage(users: users, rowCount: users.count, totalCount: users.count)
    }

    func relation(to mid: Int64) async throws -> FollowMembership? {
        relationReads.append(mid)
        return relations[mid]
    }

    func waitForGroupReadCount(_ target: Int) async {
        await withCheckedContinuation {
            groupReadWaiters.add($0, until: target, current: groupReadCount)
        }
    }
}

/// 关注关系写入也记在共用的写入替身里，与关注、取消关注同一份 `calls`，同一个人的写入顺序因此可以一起断言。
extension AccountWriteRepositoryStub: FollowRelationWriteRepository {
    func setSpecial(
        _ isSpecial: Bool,
        uploader: UploaderWriteTarget,
        accountID: Int64
    ) async throws {
        try await record("\(isSpecial ? "special" : "unspecial") \(uploader.mid) \(accountID)")
    }

    func assignGroups(
        _ membership: FollowMembership,
        uploader: UploaderWriteTarget,
        accountID: Int64
    ) async throws {
        let ids =
            (membership.isSpecial ? [FollowGroup.specialID] : [])
            + membership.customGroupIDs.sorted()
        try await record("groups \(uploader.mid) \(ids) \(accountID)")
    }
}

/// 不经窗口组装、单独构造写入协调者或效果路由时的关注依赖：关系存储、侧栏分组与关注页共用一个空的读取替身，账户取自
/// `writableAccount`。
@MainActor
struct FollowWriteDependencies {
    let relations: FollowRelationStore
    let groupList: FollowGroupListModel
    let session: FollowListSession

    init(writableAccount: @escaping @MainActor () -> WritableAccount?) {
        let useCase = FollowListUseCase(repository: FollowListRepositoryStub())
        let relations = FollowRelationStore(useCase: useCase, writableAccount: writableAccount)
        groupList = FollowGroupListModel(
            useCase: useCase,
            accountScope: { .signedOut }
        )
        session = FollowListSession(
            model: FollowListViewModel(
                useCase: useCase,
                accountID: { nil },
                reconcile: { relations.reconcile($2, in: $1, ownerID: $0) }
            ),
            groupList: groupList
        )
        self.relations = relations
    }
}
