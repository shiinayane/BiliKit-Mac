import BiliApplication
import BiliModels

/// 本 target 的 `FollowListRepository` 替身：给出固定的分组、总人数与每页结果，并记录请求过的游标。
actor FollowListRepositoryStub: FollowListRepository {
    private let groups: [FollowGroup]
    private let totalCount: Int
    private let users: [FollowedUser]
    private(set) var requestedCursors: [FollowListCursor] = []

    init(groups: [FollowGroup] = [], totalCount: Int = 0, users: [FollowedUser] = []) {
        self.groups = groups
        self.totalCount = totalCount
        self.users = users
    }

    func groups(ownerID: Int64) async throws -> [FollowGroup] { groups }

    func followingCount(ownerID: Int64) async throws -> Int { totalCount }

    func page(
        _ cursor: FollowListCursor,
        ownerID: Int64,
        pageSize: Int
    ) async throws -> FollowListRemotePage {
        requestedCursors.append(cursor)
        return FollowListRemotePage(users: users, rowCount: users.count, totalCount: users.count)
    }

    func relation(to mid: Int64) async throws -> FollowMembership? { nil }
}
