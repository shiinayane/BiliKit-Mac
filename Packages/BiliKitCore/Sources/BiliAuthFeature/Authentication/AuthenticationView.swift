import BiliApplication
import SwiftUI

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
        .task {
            model.restoreIfNeeded()
            await model.waitForCurrentTask()
        }
        .onDisappear {
            model.cancelPresentedLoginWork()
        }
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
                Label(AuthFeatureStrings.localized("尚未登录"), systemImage: "person.crop.circle")
            } description: {
                Text(AuthFeatureStrings.localized("使用哔哩哔哩手机客户端扫码确认登录。"))
            } actions: {
                Button(AuthFeatureStrings.localized("显示登录二维码")) {
                    model.startLogin()
                }
                .buttonStyle(.borderedProminent)
            }
        case .restoring:
            progress(AuthFeatureStrings.localized("正在检查本机登录状态…"))
        case .requestingQRCode:
            progress(AuthFeatureStrings.localized("正在获取登录二维码…"))
        case .awaitingScan:
            qrContent(
                title: AuthFeatureStrings.localized("请扫码登录"),
                detail: AuthFeatureStrings.localized("打开哔哩哔哩手机客户端，扫描二维码。")
            )
        case .awaitingConfirmation:
            qrContent(
                title: AuthFeatureStrings.localized("请在手机上确认"),
                detail: AuthFeatureStrings.localized("二维码已扫描，等待手机客户端确认登录。")
            )
        case .finalizing:
            progress(AuthFeatureStrings.localized("正在验证并安全保存登录状态…"))
        case .signedIn:
            ContentUnavailableView {
                Label(AuthFeatureStrings.localized("已登录"), systemImage: "checkmark.circle.fill")
            } description: {
                Text(AuthFeatureStrings.localized("登录凭据仅保存在本机 Keychain。"))
            } actions: {
                Button(AuthFeatureStrings.localized("退出登录"), role: .destructive) {
                    model.logout()
                }
            }
        case .signingOut:
            progress(AuthFeatureStrings.localized("正在清除本机登录状态…"))
        case .expired:
            terminalContent(
                title: AuthFeatureStrings.localized("二维码已过期"),
                systemImage: "clock.badge.exclamationmark",
                detail: AuthFeatureStrings.localized("请重新生成二维码。")
            )
        case .failed(let failure):
            terminalContent(
                title: AuthFeatureStrings.localized("登录未完成"),
                systemImage: "exclamationmark.triangle",
                detail: message(for: failure)
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

    private func message(for failure: AuthenticationFailure) -> String {
        switch failure {
        case .network:
            AuthFeatureStrings.localized("网络暂时不可用，请稍后重试。")
        case .serviceUnavailable:
            AuthFeatureStrings.localized("登录服务未接受本次请求，请重新扫码。")
        case .invalidResponse:
            AuthFeatureStrings.localized("登录协议返回了无法安全处理的数据。")
        case .credentialUnavailable:
            AuthFeatureStrings.localized("无法访问本机 Keychain；请解锁 Mac 后重试。")
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
