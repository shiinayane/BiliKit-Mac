import BiliModels

/// 特别关注与设置分组的写入 port。
///
/// 实现是 BiliAPI 的 `BiliFollowRelationWriteRepository`，只经 `FollowRelationWriteUseCase` 调用；`accountID` 交给写授权器
/// 做账户绑定，失败抛出 `AccountWriteError`，取消原样传播；不重试、不排队。关注与取消关注在 `VideoEngagementRepository`。
public protocol FollowRelationWriteRepository: Sendable {
    /// 把已关注的人加入（`isSpecial`）或移出特别关注。
    func setSpecial(_ isSpecial: Bool, uploader: UploaderWriteTarget, accountID: Int64) async throws
    /// 让已关注的人恰好在 `membership` 的分组里；接口按完整集合覆盖，实现负责把它编码成请求。
    func assignGroups(
        _ membership: FollowMembership,
        uploader: UploaderWriteTarget,
        accountID: Int64
    ) async throws
}

/// 特别关注与设置分组：校验账户后执行，成功时给出带写前关系的效果。
///
/// 写前关系由调用方（App 的写入协调者）取自窗口的关系存储，这里只原样放进效果，供各窗口按前后差异调整人数。只对已确认
/// 关注的人调用由协调者保证：对没关注的人发出时服务端会不会顺带关注没有实测。
public struct FollowRelationWriteUseCase: Sendable {
    private let repository: any FollowRelationWriteRepository

    public init(repository: any FollowRelationWriteRepository) {
        self.repository = repository
    }

    /// 账户 mid 不是正数、或这个人就是账户自己时不发请求（`invalidRequest`）。
    public func setSpecial(
        _ isSpecial: Bool,
        uploader: UploaderWriteTarget,
        accountID: Int64,
        before: FollowMembership?
    ) async throws -> AccountWriteEffect {
        guard accountID > 0, uploader.mid != accountID else {
            throw AccountWriteError.invalidRequest
        }
        try await repository.setSpecial(isSpecial, uploader: uploader, accountID: accountID)
        return AccountWriteEffect(
            accountID: accountID,
            change: .followSpecialChanged(uploader, isSpecial: isSpecial, before: before)
        )
    }

    /// 校验同 `setSpecial`；`membership` 与 `before` 相同时也不发（没有改动）。
    public func assignGroups(
        _ membership: FollowMembership,
        uploader: UploaderWriteTarget,
        accountID: Int64,
        before: FollowMembership
    ) async throws -> AccountWriteEffect {
        guard accountID > 0, uploader.mid != accountID, membership != before else {
            throw AccountWriteError.invalidRequest
        }
        try await repository.assignGroups(membership, uploader: uploader, accountID: accountID)
        return AccountWriteEffect(
            accountID: accountID,
            change: .followGroupsChanged(uploader, before: before, after: membership)
        )
    }
}
