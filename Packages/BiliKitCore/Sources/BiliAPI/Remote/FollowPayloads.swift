import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// 关注分组列表（`/x/relation/tags`，`data` 直接是数组）的一项，由 `BiliAPIClient.followGroups` 映射。
///
/// 只按账户读取（见 SECURITY-MODEL §3）。`tagid` 缺失的行丢弃；特别关注是 -10、默认分组是 0，自定义分组是正数，其他
/// 取值不认识，也丢弃。
struct FollowGroupPayload: Decodable, Sendable {
    let tagID: Int64?
    let name: String?
    let count: Int?

    private enum CodingKeys: String, CodingKey {
        case tagID = "tagid"
        case name, count
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagID = container.decodeLossyIfPresent(Int64.self, forKey: .tagID)
        name = container.decodeLossyIfPresent(String.self, forKey: .name)
        count = container.decodeLossyIfPresent(Int.self, forKey: .count)
    }

    func model() -> FollowGroup? {
        guard let tagID, tagID == FollowGroup.specialID || tagID >= FollowGroup.defaultID else {
            return nil
        }
        return FollowGroup(id: tagID, name: name ?? "", count: count ?? 0)
    }
}

/// 全部关注与关注内搜索（`/x/relation/followings`、`/x/relation/followings/search`）的 `data`。
///
/// `total` 是关注总人数（搜索时是命中数）；`list` 为 null 时按空页处理。
struct FollowingListPayload: Decodable, Sendable {
    let list: [LossyDecodable<FollowedUserPayload>]?
    let total: Int?

    func model() -> FollowListRemotePage {
        FollowListRemotePage(
            users: (list ?? []).compactMap { $0.value?.model(readsRelation: true) },
            rowCount: list?.count ?? 0,
            totalCount: total.map { max(0, $0) }
        )
    }
}

/// 关注列表里的一个人。
///
/// `readsRelation` 为 false 时（分组成员接口）不读 `attribute`、`special`、`tag`：实测那里这三个字段对每个人都是
/// 0／null，读了会把“不知道”当成“不在任何分组”。全部关注与搜索里：`attribute` 6 是互相关注；`special` 1 是特别关注；
/// `tag` 是所在分组（null 即只在默认分组），其中的 -10 与特别关注重复，由 `FollowMembership` 去掉。
struct FollowedUserPayload: Decodable, Sendable {
    let mid: Int64?
    let name: String?
    let face: String?
    let sign: String?
    let officialDescription: String?
    let vip: MemberVIPPayload?
    let attribute: Int?
    let special: Int?
    let tag: [Int64]?

    private enum CodingKeys: String, CodingKey {
        case mid
        case name = "uname"
        case face, sign, vip, attribute, special, tag
        case official = "official_verify"
    }

    private enum OfficialKeys: String, CodingKey {
        case desc
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mid = container.decodeLossyIfPresent(Int64.self, forKey: .mid)
        name = container.decodeLossyIfPresent(String.self, forKey: .name)
        face = container.decodeLossyIfPresent(String.self, forKey: .face)
        sign = container.decodeLossyIfPresent(String.self, forKey: .sign)
        officialDescription =
            (try? container.nestedContainer(keyedBy: OfficialKeys.self, forKey: .official))
            .flatMap { $0.decodeLossyIfPresent(String.self, forKey: .desc) }
        vip = container.decodeLossyIfPresent(MemberVIPPayload.self, forKey: .vip)
        attribute = container.decodeLossyIfPresent(Int.self, forKey: .attribute)
        special = container.decodeLossyIfPresent(Int.self, forKey: .special)
        tag = container.decodeLossyIfPresent([Int64].self, forKey: .tag)
    }

    /// 不是正数的 mid 丢弃整行。
    func model(readsRelation: Bool) -> FollowedUser? {
        guard let mid, mid > 0 else { return nil }
        return FollowedUser(
            id: mid,
            name: name ?? "",
            avatarURL: face.flatMap(WebImageURL.parse),
            signature: sign ?? "",
            officialDescription: officialDescription ?? "",
            isVIP: vip?.isActive ?? false,
            membership: readsRelation
                ? FollowMembership(isSpecial: special == 1, customGroupIDs: Set(tag ?? []))
                : nil,
            isMutual: readsRelation ? attribute == Self.mutualAttribute : nil
        )
    }

    /// `attribute` 的取值：2 已关注，6 互相关注；0 未关注，128 已拉黑。
    static let followingAttributes: Set<Int> = [2, mutualAttribute]
    static let mutualAttribute = 6
}

/// 单人关系（`/x/relation`）的 `data`；字段含义同列表里的那几个。
struct FollowRelationPayload: Decodable, Sendable {
    let attribute: Int?
    let special: Int?
    let tag: [Int64]?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attribute = container.decodeLossyIfPresent(Int.self, forKey: .attribute)
        special = container.decodeLossyIfPresent(Int.self, forKey: .special)
        tag = container.decodeLossyIfPresent([Int64].self, forKey: .tag)
    }

    private enum CodingKeys: String, CodingKey {
        case attribute, special, tag
    }

    /// 没有关注（含拉黑）时为 nil；缺 `attribute` 时不知道是否关注，按解码失败，不猜。
    func model() throws -> FollowMembership? {
        guard let attribute else { throw BiliAPIError.decodingFailed }
        guard FollowedUserPayload.followingAttributes.contains(attribute) else { return nil }
        return FollowMembership(isSpecial: special == 1, customGroupIDs: Set(tag ?? []))
    }
}
