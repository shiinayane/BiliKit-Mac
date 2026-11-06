/// 窗口账户复核的参与者：发现凭据失效的 ViewModel 递增自己的复核代次，由窗口汇总后调用一次认证复核。
///
/// 参与者不直接调用认证服务，也不经单独回调；窗口（App 的 `AccountRevalidationParticipants`）在组装处收集
/// 参与者一次，比较前后代次决定是否复核，并在复核结束时把结果交回。参与者只拥有自己的代次与复核后的恢复，
/// 不拥有复核本身（认证 ViewModel）。
@MainActor
public protocol AccountRevalidationParticipant: AnyObject {
    /// 发现需要复核账户的失败时以 `&+=` 递增，此外从不变化。
    ///
    /// 窗口只比较前后值是否不等，不比较大小：回绕到 `Int.min` 仍算一次新请求。
    var authenticationRevalidationGeneration: Int { get }

    /// 认证复核确认仍已登录。默认不动作；需要在复核后恢复内容的参与者自己实现。
    func authenticationRevalidationSucceeded()

    /// 认证复核确认窗口未登录（凭据已不在本机）。默认不动作：只在已登录时显示的页面随账户范围变化离开。
    ///
    /// 未登录也能匿名读取的页面（首页推荐、热门、搜索、UP 主空间）在这里重载自己因凭据失败停住的内容。复核前凭据已被某次读取删除时，
    /// 账户范围不会变化，不会经账户会话同步重载，只有这里能让它恢复。
    func authenticationRevalidationConfirmedSignedOut()

    /// 认证复核没能确认登录状态（网络或 Keychain 不可用）。默认不动作。
    func authenticationRevalidationFailed()
}

extension AccountRevalidationParticipant {
    public func authenticationRevalidationSucceeded() {}

    public func authenticationRevalidationConfirmedSignedOut() {}

    public func authenticationRevalidationFailed() {}
}
