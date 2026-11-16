import BiliApplication
import BiliModels

/// 本 target 的 `FollowListRepository` 替身：给出固定的分组与每页结果（每次请求都一样），总人数可以失败，记录请求过的
/// 游标。
actor FollowListRepositoryStub: FollowListRepository {
    private var groups: [FollowGroup]
    private let totalCount: Result<Int, ContentApplicationError>
    private let users: [FollowedUser]
    private(set) var requestedCursors: [FollowListCursor] = []

    init(
        groups: [FollowGroup] = [],
        totalCount: Result<Int, ContentApplicationError> = .success(0),
        users: [FollowedUser] = [FollowedUser(id: 11, name: "甲")]
    ) {
        self.groups = groups
        self.totalCount = totalCount
        self.users = users
    }

    func replaceGroups(_ groups: [FollowGroup]) {
        self.groups = groups
    }

    func groups(ownerID: Int64) async throws -> [FollowGroup] { groups }

    func followingCount(ownerID: Int64) async throws -> Int { try totalCount.get() }

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
