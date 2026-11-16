import BiliApplication
import BiliModels
import Observation

/// 「设置分组…」面板的状态：一个已关注的人此刻所在的分组（面板的底）、用户的勾选，以及由二者算出的提交内容。
///
/// 每次打开面板构造一份，由 App 的写入协调者持有到面板关闭。不拥有读取：底取自 App 窗口的关系存储（`base`，每次打开面板
/// 时由协调者让存储读一次单人关系，读到之前是加载中），重试同样交给协调者；不拥有写入（确认时协调者取 `submission` 发出）。分组的
/// 名字取自侧栏的分组列表（`groups`）。账户在协调者那里固定：窗口账户一变就关闭面板。
///
/// 接口按完整集合覆盖这个人的分组（含特别关注），所以底必须是服务端此刻的完整分组：分组未知或读不到时不能提交，宽限期内
/// 的旧读取由存储按确认值纠正（见 `FollowRelationLedger`）。勾选只记在与底配对的草稿里，底变了（其他窗口的写入确认了新值）
/// 草稿作废、勾选回到新底，不会拿旧底上的勾选覆盖别人的改动。列表里没有的分组（侧栏还没读到、或读不到）不显示，但仍在
/// 提交的集合里，不会被悄悄去掉。
@MainActor
@Observable
public final class FollowGroupPickerModel: Identifiable {
    /// 面板的底。
    public enum Base: Sendable, Equatable {
        /// 正在读这个人的分组。
        case loading
        /// 读不到，或只知道一部分（不能作完整集合的底）；给说明与重试。
        case unavailable
        case loaded(FollowMembership)
    }

    /// 面板里的一行：特别关注或一个自定义分组。
    public struct Row: Sendable, Equatable, Identifiable {
        public let id: Int64
        /// 接口给出的名字；特别关注由界面本地化，不用它。
        public let name: String
        public var isSpecial: Bool { id == FollowGroup.specialID }
    }

    public let mid: Int64

    @ObservationIgnored private let base: @MainActor () -> Base
    @ObservationIgnored private let groups: @MainActor () -> [FollowGroup]
    @ObservationIgnored private let isWriteInFlight: @MainActor () -> Bool
    /// 用户的勾选与它所基于的底；还没改过时为 nil，显示的就是底。
    private var draft: (base: FollowMembership, selection: FollowMembership)?

    /// `base`、`groups` 与 `isWriteInFlight` 在视图求值时调用：它们读的关系存储、分组列表与协调者的在途写入都是
    /// `@Observable`，面板随之更新。
    public init(
        mid: Int64,
        base: @escaping @MainActor () -> Base,
        groups: @escaping @MainActor () -> [FollowGroup],
        isWriteInFlight: @escaping @MainActor () -> Bool
    ) {
        self.mid = mid
        self.base = base
        self.groups = groups
        self.isWriteInFlight = isWriteInFlight
    }

    public var phase: Base { base() }

    /// 特别关注排第一，然后是自定义分组（侧栏顺序）；默认分组不列出：都不勾就是默认分组。
    public var rows: [Row] {
        [Row(id: FollowGroup.specialID, name: "")]
            + groups().filter { $0.kind == .custom }.map { Row(id: $0.id, name: $0.name) }
    }

    /// 此刻显示的勾选；底还没读到时为 nil。
    public var selection: FollowMembership? {
        guard case .loaded(let base) = phase else { return nil }
        guard let draft, draft.base == base else { return base }
        return draft.selection
    }

    public func isSelected(_ row: Row) -> Bool {
        guard let selection else { return false }
        return row.isSpecial ? selection.isSpecial : selection.customGroupIDs.contains(row.id)
    }

    /// 勾选或取消一行；底还没读到时不动作。
    public func setSelected(_ isSelected: Bool, row: Row) {
        guard case .loaded(let base) = phase, let selection else { return }
        var isSpecial = selection.isSpecial
        var customGroupIDs = selection.customGroupIDs
        if row.isSpecial {
            isSpecial = isSelected
        } else if isSelected {
            customGroupIDs.insert(row.id)
        } else {
            customGroupIDs.remove(row.id)
        }
        draft = (base, FollowMembership(isSpecial: isSpecial, customGroupIDs: customGroupIDs))
    }

    /// 同一个人的关注、取消关注、特别关注或设置分组正在进行：「完成」不可用并说明原因，不静默丢弃。
    public var isBlockedByWriteInFlight: Bool { isWriteInFlight() }

    /// 要提交的完整分组：底已读到、勾选与底不同且没有同一个人的写入在途时给出，否则为 nil（「完成」不可用）。
    public var submission: FollowMembership? {
        guard case .loaded(let base) = phase, let selection, selection != base,
            !isWriteInFlight()
        else { return nil }
        return selection
    }
}
