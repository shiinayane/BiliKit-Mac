/// 自动分页的尾部状态；`tailIdentity` 标识当前最后一页，变化即视为新尾部。
struct NearEndTailState<Identity: Equatable>: Equatable {
    let canLoadMore: Bool
    let tailIdentity: Identity?
    let isLoading: Bool

    static var end: Self {
        Self(canLoadMore: false, tailIdentity: nil, isLoading: false)
    }
}

/// 网格与评论侧栏共用的近尾部自动分页。
///
/// 进入阈值时每个尾部只触发一次，必须先离开阈值才会为新尾部重新布防；一次实时滚动手势
/// 最多自动加载一页。
struct NearEndPagination<Identity: Equatable> {
    private var tailIdentity: Identity?
    private var wasInsideThreshold = false
    private var triggeredTailIdentity: Identity?
    private var requiresNewGesture = false

    /// 新的实时滚动手势开始或内容整体替换时解除背压。
    mutating func releaseBackpressure() {
        requiresNewGesture = false
    }

    /// 返回 true 表示调用方应立即请求下一页。
    mutating func shouldLoadMore(
        isInsideThreshold: Bool,
        state: NearEndTailState<Identity>,
        isLiveScrolling: Bool
    ) -> Bool {
        guard
            updateGate(
                isInsideThreshold: isInsideThreshold && !requiresNewGesture,
                state: state
            )
        else { return false }
        if isLiveScrolling { requiresNewGesture = true }
        return true
    }

    mutating func reset() {
        tailIdentity = nil
        wasInsideThreshold = false
        triggeredTailIdentity = nil
        requiresNewGesture = false
    }

    private mutating func updateGate(
        isInsideThreshold: Bool,
        state: NearEndTailState<Identity>
    ) -> Bool {
        if state.tailIdentity != tailIdentity {
            let changedWhileStillInside =
                tailIdentity != nil && state.tailIdentity != nil
                && wasInsideThreshold && isInsideThreshold
            tailIdentity = state.tailIdentity
            triggeredTailIdentity = nil
            if changedWhileStillInside {
                wasInsideThreshold = true
                return false
            }
            wasInsideThreshold = false
        }
        guard state.canLoadMore, state.tailIdentity != nil else {
            wasInsideThreshold = false
            return false
        }
        defer { wasInsideThreshold = isInsideThreshold }
        guard isInsideThreshold,
            !wasInsideThreshold,
            !state.isLoading,
            triggeredTailIdentity != state.tailIdentity
        else { return false }
        triggeredTailIdentity = state.tailIdentity
        return true
    }
}
