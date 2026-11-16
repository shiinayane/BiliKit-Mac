import BiliApplication
import BiliModels

/// `FollowRelationWriteRepository` 的 B 站实现：转调窗口主 API 的特别关注与设置分组写入，失败经 `AccountWriteErrorMapping`
/// 映射为 `AccountWriteError`。
///
/// 无状态；底层 client 必须注入了账户写授权器（`LiveAPIClients.main`）。这两个接口没有已知的专门业务码，其余一律是普通
/// 业务拒绝。取消原样传播。
public struct BiliFollowRelationWriteRepository: FollowRelationWriteRepository {
    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func setSpecial(
        _ isSpecial: Bool,
        uploader: UploaderWriteTarget,
        accountID: Int64
    ) async throws {
        do {
            try await client.setFollowSpecial(isSpecial, mid: uploader.mid, accountID: accountID)
        } catch {
            throw AccountWriteErrorMapping.error(for: error) { _ in nil }
        }
    }

    public func assignGroups(
        _ membership: FollowMembership,
        uploader: UploaderWriteTarget,
        accountID: Int64
    ) async throws {
        do {
            try await client.assignFollowGroups(
                membership,
                mid: uploader.mid,
                accountID: accountID
            )
        } catch {
            throw AccountWriteErrorMapping.error(for: error) { _ in nil }
        }
    }
}
