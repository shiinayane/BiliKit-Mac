import BiliModels

/// 全部关注的排序：最近关注（默认）与最常访问。
///
/// BiliAPI 把它映射为 `order_type`（空串／`attention`）。
public enum FollowListOrder: Sendable, Hashable, CaseIterable, Identifiable {
    case recentlyFollowed
    case mostVisited

    public var id: Self { self }
}

/// 关注页的一种列表：全部关注（按排序）、关注内搜索（已规范化的关键词）或一个分组的成员。
public enum FollowListQuery: Sendable, Hashable {
    case all(FollowListOrder)
    case search(String)
    case group(Int64)
}

/// 关注列表的一页请求：列表种类与从 1 开始的页码；同时是 `PagedVideoList` 的游标。
public struct FollowListCursor: Sendable, Hashable {
    public let query: FollowListQuery
    public let page: Int

    public init(query: FollowListQuery, page: Int = 1) {
        self.query = query
        self.page = page
    }
}

/// 远端给出的一页关注列表：本页的人、接口返回的原始行数与总人数；分组成员接口不给总数（nil）。
public struct FollowListRemotePage: Sendable, Equatable {
    public let users: [FollowedUser]
    /// 接口这一页返回的行数，含解码失败或缺 MID 而丢掉的行。
    ///
    /// 到底判断按它而不按 `users.count`：满一页里混着无效行时后面还有人，按过滤后的人数会误判到底。
    public let rowCount: Int
    public let totalCount: Int?

    public init(users: [FollowedUser], rowCount: Int, totalCount: Int?) {
        self.users = users
        self.rowCount = rowCount
        self.totalCount = totalCount
    }
}

/// 关注列表、分组、人数与单人关系的读取 port；都只按账户读取，`ownerID` 由调用方从窗口账户范围给出。
///
/// 实现是 BiliAPI 的 `BiliFollowListRepository`；失败抛出 `ContentApplicationError`，取消原样传播。每页条数由
/// `FollowListUseCase.pageSize` 决定，实现不另选。
public protocol FollowListRepository: Sendable {
    /// 接口顺序的全部分组（含特别关注与默认分组）。
    func groups(ownerID: Int64) async throws -> [FollowGroup]
    /// 关注的总人数（侧栏「全部关注」的人数）。
    func followingCount(ownerID: Int64) async throws -> Int
    func page(
        _ cursor: FollowListCursor,
        ownerID: Int64,
        pageSize: Int
    ) async throws
        -> FollowListRemotePage
    /// 当前账户与 `mid` 的分组关系；没有关注这个人时为 nil。
    func relation(to mid: Int64) async throws -> FollowMembership?
}

/// 关注列表的读取规则：每页条数、到底判断、关键词规范化与侧栏分组顺序只写在这里。
public struct FollowListUseCase: Sendable {
    /// 每页人数：接口允许的上限；调小只会多发请求。
    public static let pageSize = 50
    /// 一次分页会话最多保留的人数，交给 `PagedVideoList`。
    ///
    /// 取 B 站一个账户能关注的人数上限，全部关注能翻到底；人物条目很小，比视频来源的 1000 条上限多保留不会成为负担。
    public static let maximumItemCount = 2_000

    private let repository: any FollowListRepository

    public init(repository: any FollowListRepository) {
        self.repository = repository
    }

    /// 侧栏顺序的分组：特别关注、自定义分组（按接口顺序）、默认分组。
    ///
    /// 接口把默认分组排在自定义分组之前（实测）；默认分组装着没归类的人，放最后与官方客户端一致。
    public func groups(ownerID: Int64) async throws -> [FollowGroup] {
        guard ownerID > 0 else { throw ContentApplicationError.invalidRequest }
        let groups = try await repository.groups(ownerID: ownerID)
        return groups.filter { $0.kind == .special } + groups.filter { $0.kind == .custom }
            + groups.filter { $0.kind == .default }
    }

    public func followingCount(ownerID: Int64) async throws -> Int {
        guard ownerID > 0 else { throw ContentApplicationError.invalidRequest }
        return try await repository.followingCount(ownerID: ownerID)
    }

    /// 关注内搜索的第一页；关键词规范化后为空或超长时为 nil，不发请求。
    public static func searchCursor(for keyword: String) -> FollowListCursor? {
        let normalized = SearchText.normalized(keyword)
        guard !normalized.isEmpty, SearchText.isWithinLimit(normalized) else { return nil }
        return FollowListCursor(query: .search(normalized))
    }

    /// 读取 `cursor` 这一页，并给出下一页游标。
    ///
    /// 全部关注与搜索按总人数判断到底（本页已到总数，或空页）；分组成员没有总数，不满一页或空页即到底。“一页”与
    /// “空页”都按接口返回的原始行数（`rowCount`）算。去重与条目上限由调用方的 `PagedVideoList` 承担。
    package func page(
        _ cursor: FollowListCursor,
        ownerID: Int64
    ) async throws -> (page: VideoListPage<FollowedUser, FollowListCursor>, totalCount: Int?) {
        guard ownerID > 0, cursor.page > 0 else { throw ContentApplicationError.invalidRequest }
        let remote = try await repository.page(cursor, ownerID: ownerID, pageSize: Self.pageSize)
        let reachedEnd: Bool
        switch cursor.query {
        case .all, .search:
            reachedEnd =
                remote.rowCount == 0
                || remote.totalCount.map { cursor.page * Self.pageSize >= $0 } ?? false
        case .group:
            reachedEnd = remote.rowCount < Self.pageSize
        }
        let next = reachedEnd ? nil : FollowListCursor(query: cursor.query, page: cursor.page + 1)
        return (VideoListPage(items: remote.users, nextCursor: next), remote.totalCount)
    }

    public func relation(to mid: Int64) async throws -> FollowMembership? {
        guard mid > 0 else { throw ContentApplicationError.invalidRequest }
        return try await repository.relation(to: mid)
    }
}
