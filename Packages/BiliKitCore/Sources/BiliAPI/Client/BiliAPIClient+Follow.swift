import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// 关注读取：分组列表、总人数、全部关注、关注内搜索、分组成员与单人关系。都只属于当前账户，只按账户读取，本地无凭据时
/// 直接失败（见 SECURITY-MODEL §3）。
///
/// 只有关注内搜索签 WBI（网页端如此）；其余接口实测不签也能读，签名不是认证，多签反而偏离网页端的请求形状。
extension BiliAPIClient {
    /// 读取 `ownerID` 的全部关注分组，按接口顺序；`data` 为 null 时为空。
    public func followGroups(ownerID: Int64) async throws -> [FollowGroup] {
        guard ownerID > 0 else { throw BiliAPIError.invalidRequest }
        do {
            let payload: [LossyDecodable<FollowGroupPayload>] = try await get(
                url: try endpoint(path: BiliAccountReadPath.followGroups, queryItems: []),
                referer: Self.followReferer(ownerID),
                access: .accountRead(missingCredential: .fail)
            )
            return payload.compactMap { $0.value?.model() }
        } catch BiliAPIError.missingData {
            return []
        }
    }

    /// 关注总人数：取全部关注的第一页、每页一人，只读 `total`。
    public func followingCount(ownerID: Int64) async throws -> Int {
        let page = try await followings(
            ownerID: ownerID,
            order: .recentlyFollowed,
            page: 1,
            pageSize: 1
        )
        guard let total = page.totalCount else { throw BiliAPIError.decodingFailed }
        return total
    }

    /// 读取关注列表的一页。
    public func followPage(
        _ cursor: FollowListCursor,
        ownerID: Int64,
        pageSize: Int
    ) async throws -> FollowListRemotePage {
        guard ownerID > 0, cursor.page > 0, pageSize > 0 else { throw BiliAPIError.invalidRequest }
        switch cursor.query {
        case .all(let order):
            return try await followings(
                ownerID: ownerID,
                order: order,
                page: cursor.page,
                pageSize: pageSize
            )
        case .search(let keyword):
            return try await followingSearch(
                ownerID: ownerID,
                keyword: keyword,
                page: cursor.page,
                pageSize: pageSize
            )
        case .group(let groupID):
            return try await followGroupMembers(
                ownerID: ownerID,
                groupID: groupID,
                page: cursor.page,
                pageSize: pageSize
            )
        }
    }

    /// 当前账户与 `mid` 的分组关系；没有关注时为 nil。
    public func followRelation(to mid: Int64) async throws -> FollowMembership? {
        guard mid > 0 else { throw BiliAPIError.invalidRequest }
        let payload: FollowRelationPayload = try await get(
            url: try endpoint(
                path: BiliAccountReadPath.relation,
                queryItems: [URLQueryItem(name: "fid", value: String(mid))]
            ),
            referer: "https://space.bilibili.com/\(mid)",
            access: .accountRead(missingCredential: .fail)
        )
        return try payload.model()
    }

    private func followings(
        ownerID: Int64,
        order: FollowListOrder,
        page: Int,
        pageSize: Int
    ) async throws -> FollowListRemotePage {
        guard ownerID > 0 else { throw BiliAPIError.invalidRequest }
        let payload: FollowingListPayload = try await get(
            url: try endpoint(
                path: BiliAccountReadPath.followings,
                queryItems: [
                    URLQueryItem(name: "vmid", value: String(ownerID)),
                    URLQueryItem(name: "pn", value: String(page)),
                    URLQueryItem(name: "ps", value: String(pageSize)),
                    URLQueryItem(name: "order", value: "desc"),
                    URLQueryItem(name: "order_type", value: order.apiValue)
                ]
            ),
            referer: Self.followReferer(ownerID),
            access: .accountRead(missingCredential: .fail)
        )
        return payload.model()
    }

    /// 关注内搜索：`keyword` 必须已按 `SearchText` 规范化、非空（由 `FollowListUseCase` 保证），只在用户提交时发出。
    private func followingSearch(
        ownerID: Int64,
        keyword: String,
        page: Int,
        pageSize: Int
    ) async throws -> FollowListRemotePage {
        guard !keyword.isEmpty, SearchText.isWithinLimit(keyword) else {
            throw BiliAPIError.invalidRequest
        }
        let parameters = [
            "vmid": String(ownerID),
            "pn": String(page),
            "ps": String(pageSize),
            "name": keyword
        ]
        let payload: FollowingListPayload = try await signedRequest(
            path: BiliAccountReadPath.followingSearch,
            parameters: { parameters },
            send: { url in
                try await get(
                    url: url,
                    referer: Self.followReferer(ownerID),
                    access: .accountRead(missingCredential: .fail)
                )
            }
        )
        return payload.model()
    }

    /// 分组成员：`data` 直接是数组，没有总数；成员里的关系字段无效，不读（见 `FollowedUserPayload`）。
    private func followGroupMembers(
        ownerID: Int64,
        groupID: Int64,
        page: Int,
        pageSize: Int
    ) async throws -> FollowListRemotePage {
        guard groupID == FollowGroup.specialID || groupID >= FollowGroup.defaultID else {
            throw BiliAPIError.invalidRequest
        }
        let payload: [LossyDecodable<FollowedUserPayload>]
        do {
            payload = try await get(
                url: try endpoint(
                    path: BiliAccountReadPath.followGroupMembers,
                    queryItems: [
                        URLQueryItem(name: "mid", value: String(ownerID)),
                        URLQueryItem(name: "tagid", value: String(groupID)),
                        URLQueryItem(name: "pn", value: String(page)),
                        URLQueryItem(name: "ps", value: String(pageSize))
                    ]
                ),
                referer: Self.followReferer(ownerID),
                access: .accountRead(missingCredential: .fail)
            )
        } catch BiliAPIError.missingData {
            payload = []
        }
        return FollowListRemotePage(
            users: payload.compactMap { $0.value?.model(readsRelation: false) },
            rowCount: payload.count,
            totalCount: nil
        )
    }

    private static func followReferer(_ ownerID: Int64) -> String {
        "https://space.bilibili.com/\(ownerID)/relation/follow"
    }
}

extension FollowListOrder {
    /// 排序在接口 `order_type` 参数里的取值。
    fileprivate var apiValue: String {
        switch self {
        case .recentlyFollowed: ""
        case .mostVisited: "attention"
        }
    }
}
