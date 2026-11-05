import BiliApplication

/// 资料库里只按账户读取的页面对“凭据失败”的判定，复核进度本身在共用的 `AccountRevalidationProgress`。
///
/// 资料库只在窗口已登录时显示，读取时本地没有凭据也说明窗口的登录状态已过期，所以“需要登录”同样请求复核；
/// 能匿名读取的首页不这样判断。无状态。
enum LibraryAccountRevalidation {
    /// 凭据缺失或失效：原地刷新不保留条目，并请求窗口复核账户。
    static func isCredentialFailure(_ error: ContentApplicationError) -> Bool {
        error == .authenticationRequired || error.requiresAccountRevalidation
    }
}
