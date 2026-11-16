import BiliApplication
import BiliModels

/// `FollowListRepository` 的 B 站实现：只按账户读取关注分组、总人数、列表页与单人关系，错误经内容域映射。
///
/// 无状态。
public struct BiliFollowListRepository: FollowListRepository {
    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func groups(ownerID: Int64) async throws -> [FollowGroup] {
        try await mapped { try await client.followGroups(ownerID: ownerID) }
    }

    public func followingCount(ownerID: Int64) async throws -> Int {
        try await mapped { try await client.followingCount(ownerID: ownerID) }
    }

    public func page(
        _ cursor: FollowListCursor,
        ownerID: Int64,
        pageSize: Int
    ) async throws -> FollowListRemotePage {
        try await mapped {
            try await client.followPage(cursor, ownerID: ownerID, pageSize: pageSize)
        }
    }

    public func relation(to mid: Int64) async throws -> FollowMembership? {
        try await mapped { try await client.followRelation(to: mid) }
    }

    private func mapped<Value>(_ read: () async throws -> Value) async throws -> Value {
        do {
            return try await read()
        } catch {
            throw BiliAPIError.contentApplicationError(for: error)
        }
    }
}
