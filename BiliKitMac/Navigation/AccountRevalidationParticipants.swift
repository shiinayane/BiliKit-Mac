import BiliApplication
import BiliAuthFeature

/// 一个窗口内全部账户复核参与者（`AccountRevalidationParticipant`）的集合，由 `WindowComposition` 构造一次。
///
/// 只持有参与者引用与它们所属的来源，不拥有复核：`AppRootView` 读取 `generations` 并在前后不等时调用一次认证复核，
/// 复核结束（离开 restoring）时调用 `finishRevalidation`。参与者自己的代次与复核后的恢复归各 ViewModel。
@MainActor
struct AccountRevalidationParticipants {
    /// 绑定在某个来源上的参与者只在该来源是当前来源时收到复核结果；`route` 为 nil 的参与者总是收到。
    ///
    /// 绑定关系只来自来源描述的 `revalidationParticipant`。稍后再看、观看历史与收藏夹的夹内页面复核成功后会加载，即使
    /// 它没有请求这次复核；不在本页时不能让它在后台读取账户内容。收藏夹列表是例外，按窗口级（`route` 为 nil）登记：
    /// 它是侧栏常驻的行，窗口已登录就读取，复核结果不论当前来源都交给它（见 SECURITY-MODEL §3）。
    struct Entry {
        let participant: any AccountRevalidationParticipant
        let route: AppTab?
    }

    let entries: [Entry]

    /// 各参与者当前的复核代次，顺序与 `entries` 相同、长度不变。
    ///
    /// 在 SwiftUI `body` 里读取会追踪每个参与者的代次。
    var generations: [Int] {
        entries.map(\.participant.authenticationRevalidationGeneration)
    }

    /// 任一参与者的代次变了就需要复核一次。
    ///
    /// 比较是否不等而不是大小：代次以 `&+=` 递增，回绕后仍算新请求。
    static func requestsRevalidation(from previous: [Int], to current: [Int]) -> Bool {
        previous != current
    }

    /// 认证复核离开 restoring 后调用：确认已登录或确认未登录时交给参与者恢复，没能确认时交给参与者报告；其他结果不动作。
    func finishRevalidation(
        _ phase: AuthenticationResolutionPhase,
        currentRoute: AppTab
    ) {
        for entry in entries where entry.route == nil || entry.route == currentRoute {
            switch phase {
            case .signedIn:
                entry.participant.authenticationRevalidationSucceeded()
            case .signedOut:
                entry.participant.authenticationRevalidationConfirmedSignedOut()
            case .failed:
                entry.participant.authenticationRevalidationFailed()
            case .other, .restoring:
                break
            }
        }
    }
}
