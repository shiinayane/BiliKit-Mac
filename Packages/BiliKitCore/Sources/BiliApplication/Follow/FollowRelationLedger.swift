import BiliModels

/// 写入确认的关注关系与它们的确认时刻：写入之后的宽限期内，读到的关系与分组成员可能还是写前的旧值，按这里的确认值纠正。
///
/// 存在的理由：「设置分组…」按完整集合覆盖这个人的分组，面板以读到的关系为底；写后立刻读到旧值作底时，用户只改一项就会
/// 把刚加入的分组（或特别关注）悄悄抹掉。侧栏人数的旧值不在这里处理，见 `LibrarySidebarListModel.adjustAfterWrite`。
///
/// 纯值类型，不观察、不计时：时刻都由调用方传入（App 的 `FollowRelationStore` 传 `ContinuousClock.now`，并由它在宽限期结束时
/// 补读）。每个窗口一份，随窗口账户清空；只记写入确认的值，读到的值由调用方另存。
public struct FollowRelationLedger: Sendable {
    /// 写入之后多久内不信任与确认值矛盾的读取。
    ///
    /// 实测写后立刻读到的关系与人数是旧值，第二次实测几秒内已一致；取 15 秒留出余量。调长时宽限期内的关系与关注页更久不随
    /// 服务端变化、补读更晚；调短可能让旧值盖过确认值。
    public static let relationReadLagGrace: Duration = .seconds(15)

    private struct Confirmation: Sendable {
        let relation: FollowRelation
        let instant: ContinuousClock.Instant
    }

    private var confirmations: [Int64: Confirmation] = [:]
    /// 最近一次确认写入的时刻；关注页的补读按它判断（任何一个人的关系变化都可能改动正在显示的那一页）。
    private var latestConfirmation: ContinuousClock.Instant?

    public init() {}

    /// 记下一次写入确认的关系；过期的确认同时丢弃，条目数不超过宽限期内写入过的人数。
    public mutating func confirm(
        _ relation: FollowRelation,
        for mid: Int64,
        at now: ContinuousClock.Instant
    ) {
        confirmations = confirmations.filter { Self.isWithinGrace($0.value.instant, at: now) }
        confirmations[mid] = Confirmation(relation: relation, instant: now)
        latestConfirmation = now
    }

    /// 宽限期结束的时刻：最近一次确认加上宽限期；此刻已不在宽限期内时为 nil。
    public func graceEnd(at now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        guard let latestConfirmation, Self.isWithinGrace(latestConfirmation, at: now) else {
            return nil
        }
        return latestConfirmation.advanced(by: Self.relationReadLagGrace)
    }

    /// 宽限期内写入确认的这个人的关系；没有或已过期时为 nil。
    public func confirmedRelation(
        for mid: Int64,
        at now: ContinuousClock.Instant
    ) -> FollowRelation? {
        guard let confirmation = confirmations[mid],
            Self.isWithinGrace(confirmation.instant, at: now)
        else { return nil }
        return confirmation.relation
    }

    /// 读到的单人关系：宽限期内与确认值矛盾时按确认值，过期后信任服务端。
    ///
    /// 确认值只知道特别关注时，读到的自定义分组照用。
    public func reconciled(
        _ read: FollowRelation,
        for mid: Int64,
        at now: ContinuousClock.Instant
    ) -> FollowRelation {
        guard let confirmed = confirmedRelation(for: mid, at: now) else { return read }
        guard case .followingWithUnknownGroups(let isSpecial) = confirmed else { return confirmed }
        switch read {
        case .following(let membership):
            return .following(isSpecial.map(membership.settingSpecial) ?? membership)
        case .followingWithUnknownGroups(let readIsSpecial):
            return .followingWithUnknownGroups(isSpecial: isSpecial ?? readIsSpecial)
        case .notFollowing:
            return confirmed
        }
    }

    /// 关注页 `query` 的一页：宽限期内确认已不关注的人去掉；分组页去掉确认已不在这个分组的人；全部关注与搜索里的人换成
    /// 确认的分组。
    ///
    /// 刚加入这个分组（或刚关注）的人不插入：位置与排序只有服务端知道。调用方在 `graceEnd` 之后补读这一页。
    public func reconciled(
        _ users: [FollowedUser],
        in query: FollowListQuery,
        at now: ContinuousClock.Instant
    ) -> [FollowedUser] {
        users.compactMap { user in
            guard let confirmed = confirmedRelation(for: user.id, at: now) else { return user }
            if case .group(let groupID) = query {
                return confirmed.allowsMembership(in: groupID) ? user : nil
            }
            switch reconciled(.implied(by: user, in: query), for: user.id, at: now) {
            case .notFollowing:
                return nil
            case .following(let membership):
                return user.replacingMembership(membership)
            case .followingWithUnknownGroups:
                return user
            }
        }
    }

    private static func isWithinGrace(
        _ instant: ContinuousClock.Instant,
        at now: ContinuousClock.Instant
    ) -> Bool {
        now < instant.advanced(by: relationReadLagGrace)
    }
}

extension FollowedUser {
    /// 同一个人换上另一份分组。
    fileprivate func replacingMembership(_ membership: FollowMembership) -> FollowedUser {
        FollowedUser(
            id: id,
            name: name,
            avatarURL: avatarURL,
            signature: signature,
            officialDescription: officialDescription,
            isVIP: isVIP,
            membership: membership,
            isMutual: isMutual
        )
    }
}
