/// 按窗口账户绑定的面板（「收藏到…」「设置分组…」）的打开、关闭、重试、账户变化与确认规则，两种面板共用。
///
/// 保存面板模型与打开时的窗口账户（含会话代次）。窗口账户一变就关闭，重试与确认前再核对一次：面板里的内容属于打开时的
/// 账户，在另一个账户下显示、重读或提交，就会用新账户的 Cookie 读旧账户的 mid，或改动错的账户（见 SECURITY-MODEL §3）。
/// 值类型，由写入协调者持有（协调者是 `@Observable`，`model` 的变化随之被观察，`AppShellView` 据此呈现 sheet）；关闭时调用
/// 构造时给出的 `cancel`（面板模型自己的读取 Task 归模型）。
@MainActor
struct AccountBoundPanel<Model: AnyObject> {
    /// 正在显示的面板；nil 时不显示。
    private(set) var model: Model?
    private var account: WritableAccount?
    private let cancel: @MainActor (Model) -> Void

    /// `cancel` 在面板关闭（含被新面板替换）时调用一次。
    init(cancel: @escaping @MainActor (Model) -> Void) {
        self.cancel = cancel
    }

    /// 打开面板；已有面板时先关闭它。
    mutating func open(_ model: Model, account: WritableAccount) {
        close()
        self.model = model
        self.account = account
    }

    /// 面板的取消、sheet 被系统关闭与关窗。
    mutating func close() {
        if let model { cancel(model) }
        model = nil
        account = nil
    }

    /// 重试前的核对：窗口账户仍是打开时的账户就交出面板，否则关闭面板、返回 nil。
    mutating func modelForRetry(currentAccount: WritableAccount?) -> Model? {
        guard model != nil else { return nil }
        guard currentAccount == account else {
            close()
            return nil
        }
        return model
    }

    /// 窗口的写入账户变了（登出、换号、其他窗口换号待复核、会话代次变化）：属于旧账户的面板立即关闭。
    mutating func closeIfAccountChanged(currentAccount: WritableAccount?) {
        guard model != nil, currentAccount != account else { return }
        close()
    }

    /// 确认：关闭面板；窗口账户此刻仍是打开时的账户才交出面板与账户，否则丢弃（按上一账户的内容提交会改动错的账户）。
    mutating func closeForConfirmation(
        currentAccount: WritableAccount?
    ) -> (model: Model, account: WritableAccount)? {
        guard let model else { return nil }
        let account = account
        close()
        guard let account, currentAccount == account else { return nil }
        return (model, account)
    }
}
