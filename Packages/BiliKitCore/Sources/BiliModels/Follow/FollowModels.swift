import Foundation

/// 一个人在当前账户关注分组里的位置：是否特别关注，以及所在的自定义分组。
///
/// 特别关注在接口里是 tagid -10 的分组，这里单独成一个字段；`customGroupIDs` 不含 -10 与默认分组 0。默认分组不是一个
/// 独立的归属，而是“不特别关注、也不在任何自定义分组”（实测：只加入特别关注时默认分组人数减一）。人数调整、「设置分组…」
/// 面板与写入效果都只用这一种表示。
public struct FollowMembership: Sendable, Hashable {
    public let isSpecial: Bool
    public let customGroupIDs: Set<Int64>

    public init(isSpecial: Bool, customGroupIDs: Set<Int64>) {
        self.isSpecial = isSpecial
        self.customGroupIDs = customGroupIDs.filter { $0 > 0 }
    }

    /// 刚关注的人所在的位置：只在默认分组。
    public static let defaultGroupOnly = FollowMembership(isSpecial: false, customGroupIDs: [])

    public var isInDefaultGroup: Bool { !isSpecial && customGroupIDs.isEmpty }

    /// 加入或移出特别关注之后的位置：自定义分组不变。
    ///
    /// 只假定特别关注的加入与移出不动自定义分组（移出已实测，加入未实测）。
    public func settingSpecial(_ isSpecial: Bool) -> FollowMembership {
        FollowMembership(isSpecial: isSpecial, customGroupIDs: customGroupIDs)
    }

    /// 侧栏各行按 id 计数时，这个人算在哪几行（特别关注、各自定义分组，或只算默认分组）。
    public var groupIDs: Set<Int64> {
        if isInDefaultGroup { return [FollowGroup.defaultID] }
        var ids = customGroupIDs
        if isSpecial { ids.insert(FollowGroup.specialID) }
        return ids
    }
}

/// 当前账户的一个关注分组：特别关注、自定义分组或默认分组，带人数。
public struct FollowGroup: Sendable, Equatable, Identifiable {
    /// 特别关注在接口里的 tagid。
    public static let specialID: Int64 = -10
    /// 默认分组在接口里的 tagid。
    public static let defaultID: Int64 = 0

    public enum Kind: Sendable, Equatable {
        case special
        case custom
        case `default`
    }

    public let id: Int64
    /// 接口给出的名字；特别关注与默认分组由界面按 `kind` 本地化，不用它。
    public let name: String
    public let count: Int

    public init(id: Int64, name: String, count: Int) {
        self.id = id
        self.name = name
        self.count = max(0, count)
    }

    public var kind: Kind {
        switch id {
        case Self.specialID: .special
        case Self.defaultID: .default
        default: .custom
        }
    }
}

/// 关注列表里的一个人。
///
/// `membership` 与 `isMutual` 只有全部关注与关注内搜索给出；分组成员接口里这几个字段无效，为 nil，表示不知道，不能当成
/// “不在任何分组”或“不是互相关注”。
public struct FollowedUser: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let name: String
    public let avatarURL: URL?
    public let signature: String
    /// 认证说明（如“bilibili 知名UP主”）；没有认证时为空。
    public let officialDescription: String
    public let isVIP: Bool
    public let membership: FollowMembership?
    public let isMutual: Bool?

    public init(
        id: Int64,
        name: String,
        avatarURL: URL? = nil,
        signature: String = "",
        officialDescription: String = "",
        isVIP: Bool = false,
        membership: FollowMembership? = nil,
        isMutual: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
        self.signature = signature
        self.officialDescription = officialDescription
        self.isVIP = isVIP
        self.membership = membership
        self.isMutual = isMutual
    }
}

/// UP 主空间的网页地址；卡片菜单的「拷贝链接」「在浏览器中打开」只经这里构造。
public enum UploaderSpaceWebLink {
    /// 只收正整数 mid，其他取值为 nil，不拼出指向别处的地址（见 SECURITY-MODEL §4）。
    public static func url(mid: Int64) -> URL? {
        guard mid > 0 else { return nil }
        return URL(string: "https://space.bilibili.com/\(mid)")
    }
}
