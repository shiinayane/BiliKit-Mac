import BiliModels

/// 当前账户与一个人的关系里已知的部分：单人关系的读取、关注页的一页或写入确认给出。
///
/// 菜单（「加入／移出特别关注」的标题与可用性）、「设置分组…」面板的底、写入的前置条件与人数调整都只看它。分组未知
/// （`followingWithUnknownGroups`）与完全不知道（调用方没有这个值）是两回事：前者已知关注，可以取消关注或改特别关注，但
/// 不能作「设置分组…」的底。
public enum FollowRelation: Sendable, Hashable {
    case notFollowing
    /// 已关注，分组已知。
    case following(FollowMembership)
    /// 已关注，分组未知；`isSpecial` 已知时不为 nil（特别关注页里的人、写前分组未知的特别关注写入）。
    case followingWithUnknownGroups(isSpecial: Bool?)

    /// 单人关系读取的结果：没有关注时接口给 nil。
    public init(read membership: FollowMembership?) {
        self = membership.map(Self.following) ?? .notFollowing
    }

    public var isFollowing: Bool {
        if case .notFollowing = self { false } else { true }
    }

    /// 已知的全部分组；没有关注或分组未知时为 nil。
    public var membership: FollowMembership? {
        if case .following(let membership) = self { membership } else { nil }
    }

    /// 是否在特别关注；没有关注时为 false，不知道时为 nil。
    public var isSpecial: Bool? {
        switch self {
        case .notFollowing: false
        case .following(let membership): membership.isSpecial
        case .followingWithUnknownGroups(let isSpecial): isSpecial
        }
    }

    /// 按已知的部分，这个人是否可能在 `groupID` 这个分组（特别关注、默认分组或自定义分组）里；分组未知时只按是否特别关注
    /// 排除（特别关注的人不在默认分组）。
    public func allowsMembership(in groupID: Int64) -> Bool {
        switch self {
        case .notFollowing:
            false
        case .following(let membership):
            membership.groupIDs.contains(groupID)
        case .followingWithUnknownGroups(let isSpecial):
            switch groupID {
            case FollowGroup.specialID: isSpecial != false
            case FollowGroup.defaultID: isSpecial != true
            default: true
            }
        }
    }

    /// 关注页 `query` 这一页里的 `user` 说明了什么：全部关注与搜索给出分组；默认分组页里的人只在默认分组；特别关注页里的人
    /// 在特别关注、其他分组未知；自定义分组页只说明已关注（分组成员接口不给分组，见 `FollowedUser`）。
    public static func implied(by user: FollowedUser, in query: FollowListQuery) -> Self {
        if let membership = user.membership { return .following(membership) }
        guard case .group(let groupID) = query else {
            return .followingWithUnknownGroups(isSpecial: nil)
        }
        switch groupID {
        case FollowGroup.defaultID: return .following(.defaultGroupOnly)
        case FollowGroup.specialID: return .followingWithUnknownGroups(isSpecial: true)
        default: return .followingWithUnknownGroups(isSpecial: nil)
        }
    }

    /// 加入（`isSpecial`）或移出特别关注之后的关系。
    ///
    /// 写前分组 `before` 已知时只改特别关注，否则分组仍未知、只知道是否特别关注。发起写入的乐观改动与各窗口的效果都按它
    /// 推出。
    public static func settingSpecial(_ isSpecial: Bool, before: FollowMembership?) -> Self {
        before.map { .following($0.settingSpecial(isSpecial)) }
            ?? .followingWithUnknownGroups(isSpecial: isSpecial)
    }

    /// 用较新的 `newer`（关注页 `query` 这一页说明的关系）更新已知的 `older`：`newer` 只知道一部分、且与 `older` 不矛盾时
    /// 保留 `older` 里更多的信息。
    ///
    /// 自定义分组页说明这个人在这个分组里：`older` 的完整分组不含它就是过时的，降为分组未知、只保留特别关注；留着它会让
    /// 「设置分组…」以过时的完整集合为底、提交时把这个分组抹掉。
    public static func merging(_ newer: Self, over older: Self?, in query: FollowListQuery) -> Self
    {
        guard case .followingWithUnknownGroups(let isSpecial) = newer else { return newer }
        switch older {
        case .following(let membership) where isSpecial == nil || isSpecial == membership.isSpecial:
            if case .group(let groupID) = query, groupID > 0,
                !membership.customGroupIDs.contains(groupID)
            {
                return .followingWithUnknownGroups(isSpecial: membership.isSpecial)
            }
            return .following(membership)
        case .followingWithUnknownGroups(let olderIsSpecial):
            return .followingWithUnknownGroups(isSpecial: isSpecial ?? olderIsSpecial)
        case .following, .notFollowing, nil:
            return newer
        }
    }
}
