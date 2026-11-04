import BiliApplication
import SwiftUI

/// 登录门槛的形态：只由账户呈现状态决定，与具体来源无关。
package enum AccountGatePhase: Sendable, Equatable {
    /// 已登录：显示来源内容。
    case content
    /// 确定登出：请用户登录。
    case signIn
    /// 仍在确认登录状态。
    case progress
    /// 暂时无法确认（本机凭据未被清除）：引导到账号页面，不当作登出。
    case unavailable

    package init(_ state: AccountPresentationState) {
        switch state {
        case .signedIn: self = .content
        case .signedOut: self = .signIn
        case .resolving: self = .progress
        case .unavailable: self = .unavailable
        }
    }
}

/// 只按账户读取的来源共用的登录门槛：按 `AccountGatePhase` 显示来源内容、登录提示、进度或账号页面入口。
///
/// 只负责呈现。登录标题与说明由来源提供，登录与账号页面的打开动作由调用方注入；内容的加载与清理仍由
/// 来源自己的 ViewModel 负责。
package struct AccountGateView<SignedInContent: View>: View {
    @Environment(\.locale) private var locale
    private let phase: AccountGatePhase
    private let signInTitle: String
    private let signInDescription: String
    private let onPresentAuthentication: () -> Void
    private let signedInContent: () -> SignedInContent

    package init(
        state: AccountPresentationState,
        signInTitle: String,
        signInDescription: String,
        onPresentAuthentication: @escaping () -> Void,
        @ViewBuilder signedInContent: @escaping () -> SignedInContent
    ) {
        phase = AccountGatePhase(state)
        self.signInTitle = signInTitle
        self.signInDescription = signInDescription
        self.onPresentAuthentication = onPresentAuthentication
        self.signedInContent = signedInContent
    }

    package var body: some View {
        switch phase {
        case .content:
            signedInContent()
        case .signIn:
            ContentUnavailableView {
                Label(signInTitle, systemImage: "person.crop.circle")
            } description: {
                Text(signInDescription)
            } actions: {
                Button(
                    BiliUIStrings.localized("登录", locale: locale),
                    action: onPresentAuthentication
                )
                .buttonStyle(.borderedProminent)
                .accessibilityHint(BiliUIStrings.localized("打开扫码登录", locale: locale))
            }
        case .progress:
            ProgressView(BiliUIStrings.localized("正在检查登录状态…", locale: locale))
                .revealsAfterLoadingDelay()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                Label(
                    BiliUIStrings.localized("暂时无法确认登录状态", locale: locale),
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
            } description: {
                Text(BiliUIStrings.localized("本机登录状态没有被自动清除，请在账号页面重试。", locale: locale))
            } actions: {
                Button(
                    BiliUIStrings.localized("查看账号状态", locale: locale),
                    action: onPresentAuthentication
                )
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
