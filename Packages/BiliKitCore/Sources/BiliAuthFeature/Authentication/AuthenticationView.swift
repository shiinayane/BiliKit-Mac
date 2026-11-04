import BiliApplication
import BiliUI
import SwiftUI

/// 账号 sheet 的内容：按 `AuthenticationViewModel` 的状态显示未登录、进度、二维码、已登录或失败，
/// 并转发登录、取消、重试与退出意图。
///
/// 只负责呈现；出现时触发一次启动恢复并等待当前操作，消失时经 `cancelPresentedLoginWork`
/// 只取消本界面发起的登录挑战，恢复、确认与登出仍在模型里继续。状态变化按 `AuthenticationStatusText`
/// 的规则通告给读屏。
public struct AuthenticationView: View {
    @Environment(\.dismiss) private var dismiss
    private let model: AuthenticationViewModel

    public init(model: AuthenticationViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Text(AuthFeatureStrings.localized("账号"))
                    .font(.title2.weight(.semibold))

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(28)

            HStack {
                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text(AuthFeatureStrings.localized("完成"))
                }
                .modifier(AuthenticationCompletionButtonStyle())
                .keyboardShortcut(.cancelAction)
                .accessibilityHint(dismissalHint)
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
        }
        .frame(width: 420)
        .frame(minHeight: 420)
        .accessibilityAnnouncement(announcement, trigger: announcement)
        .task {
            model.restoreIfNeeded()
            await model.waitForCurrentTask()
        }
        .onDisappear {
            model.cancelPresentedLoginWork()
        }
    }

    private var announcement: String? {
        AuthenticationStatusText.announcement(for: model.state)
    }

    private var dismissalHint: String {
        switch model.state {
        case .requestingQRCode, .awaitingScan, .awaitingConfirmation:
            AuthFeatureStrings.localized("关闭并取消本次登录。")
        case .restoring, .finalizing, .signingOut:
            AuthFeatureStrings.localized("关闭后，此操作仍会在后台继续。")
        case .failed where model.canCancelFailure:
            AuthFeatureStrings.localized("关闭并取消本次登录。")
        case .signedOut, .signedIn, .expired, .failed:
            AuthFeatureStrings.localized("关闭账号窗口。")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .signedOut:
            ContentUnavailableView {
                Label(
                    AuthenticationStatusText.title(for: model.state),
                    systemImage: "person.crop.circle"
                )
            } description: {
                Text(AuthFeatureStrings.localized("使用哔哩哔哩手机客户端扫码确认登录。"))
            } actions: {
                Button(AuthFeatureStrings.localized("显示登录二维码")) {
                    model.startLogin()
                }
                .buttonStyle(.borderedProminent)
            }
        case .restoring, .requestingQRCode, .finalizing, .signingOut:
            progress(AuthenticationStatusText.title(for: model.state))
        case .awaitingScan:
            qrContent(
                title: AuthenticationStatusText.title(for: model.state),
                detail: AuthFeatureStrings.localized("打开哔哩哔哩手机客户端，扫描二维码。")
            )
        case .awaitingConfirmation:
            qrContent(
                title: AuthenticationStatusText.title(for: model.state),
                detail: AuthFeatureStrings.localized("二维码已扫描，等待手机客户端确认登录。")
            )
        case .signedIn:
            ContentUnavailableView {
                Label(
                    AuthenticationStatusText.title(for: model.state),
                    systemImage: "checkmark.circle.fill"
                )
            } description: {
                Text(AuthFeatureStrings.localized("登录凭据仅保存在本机 Keychain。"))
            } actions: {
                Button(AuthFeatureStrings.localized("退出登录"), role: .destructive) {
                    model.logout()
                }
            }
        case .expired:
            terminalContent(
                title: AuthenticationStatusText.title(for: model.state),
                systemImage: "clock.badge.exclamationmark",
                detail: AuthFeatureStrings.localized("请重新生成二维码。")
            )
        case .failed(let failure):
            terminalContent(
                title: AuthenticationStatusText.title(for: model.state),
                systemImage: "exclamationmark.triangle",
                detail: AuthenticationStatusText.detail(for: failure)
            )
        }
    }

    private func progress(_ title: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .revealsAfterLoadingDelay()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func qrContent(title: String, detail: String) -> some View {
        VStack(spacing: 16) {
            if let image = model.qrCodeImage {
                Image(
                    image,
                    scale: 1,
                    orientation: .up,
                    label: Text(AuthFeatureStrings.localized("哔哩哔哩登录二维码"))
                )
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 240, height: 240)
                .accessibilityHint(AuthFeatureStrings.localized("使用手机客户端扫描"))
            } else {
                ProgressView()
                    .revealsAfterLoadingDelay()
                    .frame(width: 240, height: 240)
            }
            Text(title)
                .font(.headline)
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(AuthFeatureStrings.localized("取消"), role: .cancel) {
                model.cancelLogin()
            }
        }
    }

    private func terminalContent(
        title: String,
        systemImage: String,
        detail: String
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        } actions: {
            HStack {
                if model.canClearLocalCredentials {
                    Button(AuthFeatureStrings.localized("清除本机登录状态"), role: .destructive) {
                        model.clearLocalCredentials()
                    }
                }
                if model.canCancelFailure {
                    Button(AuthFeatureStrings.localized("取消"), role: .cancel) {
                        model.cancelLogin()
                    }
                }
                Button(model.retryButtonTitle) {
                    model.retry()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct AuthenticationCompletionButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}
