/// 账户复核参与者共用的复核进度：复核代次、是否在等本页请求的复核，以及复核后是否已自动重载过。
///
/// 值类型，由参与者模型持有（资料库的列表与收藏夹模型、`BrowseViewModel`），模型的 `authenticationRevalidationGeneration`
/// 直接读它；请求、加载与复核结果的转交仍归模型。规则见 ARCHITECTURE「认证」：凭据失败时请求一次复核；复核有了确定
/// 结果后自动重载至多一次，直到下一次加载成功，挡住“复核 → 重载 → 失效 → 复核”的循环。哪种结果算确定由模型决定：
/// 只在已登录时显示的页面只认“仍已登录”，能匿名读取的页面另认“确认未登录”。
public struct AccountRevalidationProgress: Equatable, Sendable {
    /// 请求复核时以 `&+=` 递增，此外从不变化（`reset` 也不清零）；窗口只比较前后是否不等。
    public private(set) var generation = 0
    /// 本页因凭据失败请求了复核、复核尚未结束；失败页据此显示“正在重新确认”。
    public private(set) var isAwaiting = false
    /// 复核后已自动重载过一次；加载成功或 `reset` 时清除。
    private var hasReloadedAfterRevalidation = false

    public init() {}

    /// 加载因凭据失败结束：等待并请求一次复核。
    public mutating func request() {
        isAwaiting = true
        generation &+= 1
    }

    /// 加载成功：不再等待复核，下一次凭据失败后的复核又可以自动重载一次。
    public mutating func loadSucceeded() {
        isAwaiting = false
        hasReloadedAfterRevalidation = false
    }

    /// 复核有了确定结果；返回 true 时调用方重载一次（本页请求的复核、本轮还没自动重载过），否则只在空闲时加载。
    public mutating func concluded() -> Bool {
        let requested = isAwaiting
        isAwaiting = false
        guard requested, !hasReloadedAfterRevalidation else { return false }
        hasReloadedAfterRevalidation = true
        return true
    }

    /// 复核没能确认登录状态；返回这次复核是否由本页请求。
    public mutating func failed() -> Bool {
        let requested = isAwaiting
        isAwaiting = false
        return requested
    }

    /// 离开页面：App 不再把复核结果交给本页，停止等待。
    public mutating func stopAwaiting() {
        isAwaiting = false
    }

    /// 丢弃内容（登出、换号、关窗）：清除等待与重载标记，代次保留。
    public mutating func reset() {
        isAwaiting = false
        hasReloadedAfterRevalidation = false
    }
}
