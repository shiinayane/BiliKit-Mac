import BiliModels
import Foundation

/// 特别关注与设置分组的写入，经网页端表单写入管线 `postForm` 与账户写授权器发出，绑定窗口账户（见 SECURITY-MODEL §3）。
///
/// 关注与取消关注在 `BiliAPIClient+VideoEngagement`；两者共用同一个 Referer。
extension BiliAPIClient {
    /// 把已关注的 `mid` 加入（`isSpecial`）或移出特别关注。
    public func setFollowSpecial(_ isSpecial: Bool, mid: Int64, accountID: Int64) async throws {
        guard hasAccountWriteAuthorizer else {
            throw BiliAPIError.authorizationRequired
        }
        guard accountID > 0, mid > 0, mid != accountID else {
            throw BiliAPIError.invalidRequest
        }
        try await postForm(
            url: try endpoint(
                path: isSpecial
                    ? BiliAccountWritePath.followSpecialAdd
                    : BiliAccountWritePath.followSpecialRemove
            ),
            fields: [("fid", String(mid))],
            referer: Self.followWriteReferer,
            origin: Self.accountWriteOrigin,
            access: .accountWrite(expectedAccountID: accountID)
        )
    }

    /// 让已关注的 `mid` 恰好在 `membership` 的分组里：发出完整集合，不是增量。
    public func assignFollowGroups(
        _ membership: FollowMembership,
        mid: Int64,
        accountID: Int64
    ) async throws {
        guard hasAccountWriteAuthorizer else {
            throw BiliAPIError.authorizationRequired
        }
        guard accountID > 0, mid > 0, mid != accountID else {
            throw BiliAPIError.invalidRequest
        }
        try await postForm(
            url: try endpoint(path: BiliAccountWritePath.followGroupsAssign),
            fields: [("fids", String(mid)), ("tagids", Self.followGroupIDs(membership))],
            referer: Self.followWriteReferer,
            origin: Self.accountWriteOrigin,
            access: .accountWrite(expectedAccountID: accountID)
        )
    }

    /// `tagids` 的唯一编码：特别关注是 -10、自定义分组是各自的 id（升序，同一集合总是同一个请求），只在默认分组时是单独的
    /// `0`。
    ///
    /// 接口按完整集合覆盖，所以不能发空串，也不能把 0 与其他 id 混在一起（授权器同样拒绝）。
    static func followGroupIDs(_ membership: FollowMembership) -> String {
        guard !membership.isInDefaultGroup else { return String(FollowGroup.defaultID) }
        let special = membership.isSpecial ? [FollowGroup.specialID] : []
        return (special + membership.customGroupIDs.sorted()).map(String.init).joined(
            separator: ","
        )
    }
}
