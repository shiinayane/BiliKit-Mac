import BiliApplication
import BiliAuthFeature
import Synchronization

/// 本窗口是否已确认未登录；只供该窗口主 API 的授权器在 Keychain 不可用时判断能否按无凭据处理。
///
/// 已确认未登录时游客内容照常匿名请求；会话未确认、恢复中、复核失败或进程内已有窗口登录时仍失败关闭，
/// 不让已登录用户在不知情时降级为匿名。启动时 Keychain 就不可用会让复核失败，此时同样失败关闭：
/// 无法区分“从没登录”与“已登录但读不到凭据”。
///
/// 窗口在 MainActor 上 `synchronize`，授权器在请求所在的线程读 `isConfirmed`。只有这一个独立的标志，
/// 没有要和它一起更新的状态，所以用 `Atomic` 而不用锁；读写用 acquiring／releasing 配对。
final class AccountSignedOutConfirmation: Sendable {
    private let confirmed = Atomic<Bool>(false)

    var isConfirmed: Bool {
        confirmed.load(ordering: .acquiring)
    }

    func synchronize(_ isConfirmed: Bool) {
        confirmed.store(isConfirmed, ordering: .releasing)
    }

    /// 窗口状态为未登录、没有进行中或失败的复核，且进程内没有窗口已发布登录。
    ///
    /// 未登录窗口里进行中的扫码登录（`.other`）仍算已确认：凭据要到登录完成才写入。
    static func isConfirmed(
        windowScope: AccountSessionScope,
        resolutionPhase: AuthenticationResolutionPhase,
        processScope: AccountSessionScope
    ) -> Bool {
        guard windowScope == .signedOut,
            resolutionPhase == .signedOut || resolutionPhase == .other
        else { return false }
        if case .signedIn = processScope { return false }
        return true
    }
}
