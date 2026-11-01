import AppKit
import BiliUI

/// 网格的分页尾部状态；尾部身份是来源列表的尾标计数（`PagedVideoList`），变化即视为新尾部。
package typealias NativeVideoGridTailState = NearEndTailState<UInt64>

/// 一次内容更新相对上一次的差异：决定是否应用新快照、是否做差异动画、只重配内容变了的可见卡片，以及怎样保持
/// 视口锚点。
package struct NativeVideoGridUpdatePlan: Equatable {
    /// ID 序列（含顺序）变了，需要应用新快照。
    package let identityChanged: Bool
    let insertedIDs: [String]
    let removedIDs: [String]
    /// 前后都在、内容变了的卡片：ID 序列不变时只重配这些可见卡片。
    package let changedExistingIDs: Set<String>
    let isStrictTailAppend: Bool
    /// 纯删除时每张被删卡片的后继：旧顺序里它之后第一张仍在的卡片。
    ///
    /// 纯删除指只删不增、其余卡片相对顺序不变，例如稍后再看的乐观移除；不是纯删除时为空。
    private let successorsOfRemovedIDs: [String: String]

    /// 严格尾部追加不改变已有卡片的位置，不需要锚点。
    var restoresViewportAnchor: Bool { identityChanged && !isStrictTailAppend }

    /// 更新后要保持的视口锚点；nil 表示回到顶部（ARCHITECTURE「原生 AppKit 集合视图」的视口锚点条目）。
    ///
    /// 锚点卡片还在时就是它。纯删除删掉了它时，由后继按同一距离接替：后继正好补进被删卡片的位置，视野不跳。
    /// 其余情况（整体替换掉了它，或删掉的是它及其后的全部卡片，例如刷新把列表收回第一页）回到顶部：停在旧偏移会
    /// 被新内容高度截断到新内容底部，还会据此误判翻页。
    func retainedAnchor(
        _ anchor: NativeVideoGridViewportAnchor
    ) -> NativeVideoGridViewportAnchor? {
        guard removedIDs.contains(anchor.id) else { return anchor }
        return successorsOfRemovedIDs[anchor.id].map {
            NativeVideoGridViewportAnchor(
                id: $0,
                offsetFromViewportTop: anchor.offsetFromViewportTop
            )
        }
    }

    /// 是否做差异动画：身份变化、不是严格尾部追加、网格已在窗口里排过版、没开「减少动态效果」。
    ///
    /// 整体替换也做：卡片基本都不同时几乎看不出动画，历史、稍后再看刷新里相同的卡片会滑到新位置。尾部追加在视野
    /// 之下，动画看不见，却会让其后约 250ms 里的每次滚动都补建一次卡片（`NativeVideoGridClipView`），所以不做。
    /// 还没排过版时没有可见的旧位置可动画。
    func animatesDifferences(isLaidOut: Bool, reducesMotion: Bool) -> Bool {
        identityChanged && !isStrictTailAppend && isLaidOut && !reducesMotion
    }

    package init<Content: Equatable>(
        previousIDs: [String],
        previousContents: [String: Content],
        updatedIDs: [String],
        updatedContents: [String: Content]
    ) {
        identityChanged = previousIDs != updatedIDs
        let previousSet = Set(previousIDs)
        let updatedSet = Set(updatedIDs)
        insertedIDs = updatedIDs.filter { !previousSet.contains($0) }
        removedIDs = previousIDs.filter { !updatedSet.contains($0) }
        changedExistingIDs = Set(
            updatedIDs.filter {
                previousSet.contains($0) && previousContents[$0] != updatedContents[$0]
            }
        )
        isStrictTailAppend =
            updatedIDs.count > previousIDs.count
            && Array(updatedIDs.prefix(previousIDs.count)) == previousIDs
            && removedIDs.isEmpty
            && insertedIDs == Array(updatedIDs.dropFirst(previousIDs.count))
        var successors: [String: String] = [:]
        if insertedIDs.isEmpty, updatedIDs == previousIDs.filter({ updatedSet.contains($0) }) {
            var next: String?
            for id in previousIDs.reversed() {
                if updatedSet.contains(id) {
                    next = id
                } else if let next {
                    successors[id] = next
                }
            }
        }
        successorsOfRemovedIDs = successors
    }
}

/// 回顶请求的消费门：记住最后处理的请求 ID，同一个 ID 只放行一次。
struct NativeVideoGridScrollResetGate {
    private var requestID: UInt64

    init(initialRequestID: UInt64) {
        requestID = initialRequestID
    }

    mutating func consume(_ candidateRequestID: UInt64) -> Bool {
        guard candidateRequestID != requestID else { return false }
        requestID = candidateRequestID
        return true
    }
}

/// 程序把网格放回顶部之后、用户再次滚动之前，内容整体替换仍停在顶部。
///
/// 否则替换时会按旧内容第一张可见卡片做锚点恢复：刷新把新条目插到最前或把列表收回第一页时，
/// 那张卡片的位置变了，视口就被带离顶部。用户滚动会推进滚动代次，置顶随之失效。
struct NativeVideoGridTopPin: Equatable {
    private var pinnedScrollGeneration: UInt64?

    mutating func pin(atScrollGeneration generation: UInt64) {
        pinnedScrollGeneration = generation
    }

    func keepsTop(atScrollGeneration generation: UInt64) -> Bool {
        pinnedScrollGeneration == generation
    }
}

/// 调用方持有的回顶握手状态，经 binding 交给网格。
///
/// 调用方用 `request()` 递增 `requestID`；网格把偏移真正设到顶部后才把 `acknowledgedRequestID` 写成该 ID。
/// 两者不等表示请求还没落地：网格在落地前被重建，新网格从已确认的 ID 起步，仍会执行它。
public struct NativeVideoGridScrollResetState: Equatable, Sendable {
    private(set) var requestID: UInt64 = 0
    var acknowledgedRequestID: UInt64 = 0

    public init() {}

    public mutating func request() {
        requestID &+= 1
    }
}

/// 视口锚点：与视野相交的最上一行里序号最小的卡片，及其顶边到视口逻辑顶边（contentInsets 之下、逻辑偏移处）的距离。
///
/// 距离按逻辑坐标记，contentInsets 变化时网格保持逻辑偏移，锚点无需改写。
struct NativeVideoGridViewportAnchor: Equatable {
    let id: String
    let offsetFromViewportTop: CGFloat
}

/// 网格最近观察到的滚动位置，与已同步给 binding 的位置分开记：用户滚动时只记录、不逐帧写回 SwiftUI，
/// 实时滚动结束或拆除时才把超过半点的差异同步出去。
struct NativeVideoScrollOffsetRetention {
    private(set) var offsetY: CGFloat
    private var persistedOffsetY: CGFloat

    init(initialOffsetY: CGFloat) {
        offsetY = max(0, initialOffsetY)
        persistedOffsetY = offsetY
    }

    mutating func record(_ offsetY: CGFloat) {
        self.offsetY = max(0, offsetY)
    }

    mutating func takePendingPersistence() -> CGFloat? {
        guard abs(offsetY - persistedOffsetY) > 0.5 else { return nil }
        persistedOffsetY = offsetY
        return offsetY
    }

    mutating func markPersisted(_ offsetY: CGFloat) {
        record(offsetY)
        persistedOffsetY = self.offsetY
    }
}

/// 区分 binding 交回的值是网格自己同步出去的回声，还是外部写入的新请求。
struct NativeVideoScrollBindingBridge {
    private(set) var synchronizedOffsetY: CGFloat
    /// 刚被同步替换掉的旧值，binding 赶上新值后清除。
    ///
    /// SwiftUI 在同一轮更新里仍可能把它交回来，它不是新的请求。
    private var supersededOffsetY: CGFloat?

    init(initialOffsetY: CGFloat) {
        synchronizedOffsetY = max(0, initialOffsetY)
    }

    mutating func takeExternalRequest(_ offsetY: CGFloat) -> CGFloat? {
        let requestedOffsetY = max(0, offsetY)
        guard abs(requestedOffsetY - synchronizedOffsetY) > 0.5 else {
            supersededOffsetY = nil
            return nil
        }
        if let supersededOffsetY, abs(requestedOffsetY - supersededOffsetY) <= 0.5 {
            return nil
        }
        supersededOffsetY = nil
        synchronizedOffsetY = requestedOffsetY
        return requestedOffsetY
    }

    mutating func markSynchronized(_ offsetY: CGFloat) {
        let offsetY = max(0, offsetY)
        if abs(offsetY - synchronizedOffsetY) > 0.5 {
            supersededOffsetY = synchronizedOffsetY
        }
        synchronizedOffsetY = offsetY
    }
}

/// 网格几何来自 BiliUI，与加载骨架共用；预备区域与近尾部判断只属于原生网格。
typealias NativeVideoGridGeometry = VideoCardGridGeometry

extension VideoCardGridGeometry {
    /// 视野上下各多准备的高度（视野高度的倍数）：卡片提前创建，封面在滚到之前就开始加载。
    ///
    /// 调大会提前创建更多卡片、下载更多封面；调小则封面更晚开始加载，快速滚动时更容易先看到占位。
    static let preparedViewportMultiple: CGFloat = 1
    /// 已准备区域在视野某一侧的余量少于这个倍数的视野高度时刷新（已到内容边缘的一侧除外）。
    ///
    /// 调大会更频繁地重新准备，调小则余量可能在两次刷新之间耗尽。
    static let preparedRefreshViewportMultiple: CGFloat = 0.5
    /// 视野底边离内容底部不足这么多个视野高度时请求下一页，下一页的卡片与封面在滚到之前就绪。
    ///
    /// 调大会更早翻页、多加载用户未必看到的页；调小则快速滚动时可能先到底再等下一页。
    static let nearEndViewportMultiple: CGFloat = 1.5

    /// 视野上下各一屏，夹在内容范围内；不并入系统建议，避免准备区域随滚动越积越大。
    static func preparedContentRect(visible: NSRect, bounds: NSRect) -> NSRect {
        let margin = visible.height * preparedViewportMultiple
        return visible.insetBy(dx: 0, dy: -margin).intersection(bounds)
    }

    /// AppKit 只在视野超出已准备区域时才再次准备；余量不足时由网格主动刷新，保持提前量。
    static func needsPreparedContentRefresh(
        prepared: NSRect,
        visible: NSRect,
        bounds: NSRect
    ) -> Bool {
        let target = preparedContentRect(visible: visible, bounds: bounds)
        guard !target.isEmpty else { return false }
        guard !prepared.isEmpty else { return true }
        let slack = visible.height * preparedRefreshViewportMultiple
        let isShortBelow = prepared.maxY < min(target.maxY, visible.maxY + slack)
        let isShortAbove = prepared.minY > max(target.minY, visible.minY - slack)
        return isShortBelow || isShortAbove
    }

    static func isNearEnd(
        itemCount: Int,
        width: CGFloat,
        visibleMaximumY: CGFloat,
        viewportHeight: CGFloat,
        bottomInset: CGFloat
    ) -> Bool {
        guard
            itemCount > 0,
            isRenderableViewport(width: width),
            visibleMaximumY.isFinite,
            viewportHeight.isFinite,
            viewportHeight > 0
        else { return false }
        let remaining =
            contentHeight(for: width, itemCount: itemCount, bottomInset: bottomInset)
            - visibleMaximumY
        return remaining < viewportHeight * nearEndViewportMultiple
    }
}
