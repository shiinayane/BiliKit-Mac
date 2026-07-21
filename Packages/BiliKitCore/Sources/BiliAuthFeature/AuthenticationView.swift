import BiliApplication
import SwiftUI

public struct AuthenticationView: View {
    private let model: AuthenticationViewModel

    public init(model: AuthenticationViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 20) {
            Text("账号")
                .font(.title2.weight(.semibold))

            content
        }
        .padding(28)
        .frame(width: 420)
        .frame(minHeight: 420)
        .task {
            model.restoreIfNeeded()
            await model.waitForCurrentTask()
        }
        .onDisappear {
            model.cancelTransientWork()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .signedOut:
            ContentUnavailableView {
                Label("尚未登录", systemImage: "person.crop.circle")
            } description: {
                Text("使用哔哩哔哩手机客户端扫码确认登录。")
            } actions: {
                Button("显示登录二维码") {
                    model.startLogin()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("auth.start")
            }
        case .restoring:
            progress("正在检查本机登录状态…")
        case .requestingQRCode:
            progress("正在获取登录二维码…")
        case .awaitingScan:
            qrContent(
                title: "请扫码登录",
                detail: "打开哔哩哔哩手机客户端，扫描二维码。"
            )
        case .awaitingConfirmation:
            qrContent(
                title: "请在手机上确认",
                detail: "二维码已扫描，等待手机客户端确认登录。"
            )
        case .finalizing:
            progress("正在验证并安全保存登录状态…")
        case .signedIn:
            ContentUnavailableView {
                Label("已登录", systemImage: "checkmark.circle.fill")
            } description: {
                Text("登录凭据仅保存在本机 Keychain。")
            } actions: {
                Button("退出登录", role: .destructive) {
                    model.logout()
                }
                .accessibilityIdentifier("auth.logout")
            }
        case .signingOut:
            progress("正在清除本机登录状态…")
        case .expired:
            terminalContent(
                title: "二维码已过期",
                systemImage: "clock.badge.exclamationmark",
                detail: "请重新生成二维码。"
            )
        case let .failed(failure):
            terminalContent(
                title: "登录未完成",
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
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .accessibilityIdentifier("auth.qr-code")
            } else {
                ProgressView()
                    .frame(width: 240, height: 240)
            }
            Text(title)
                .font(.headline)
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("取消", role: .cancel) {
                model.cancelLogin()
            }
            .accessibilityIdentifier("auth.cancel")
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
                if model.canCancelFailure {
                    Button("取消", role: .cancel) {
                        model.cancelLogin()
                    }
                }
                Button(model.retryButtonTitle) {
                    model.retry()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("auth.retry")
            }
        }
    }

    private func message(for failure: AuthenticationFailure) -> String {
        switch failure {
        case .network:
            "网络暂时不可用，请稍后重试。"
        case .serviceUnavailable:
            "登录服务未接受本次请求，请重新扫码。"
        case .invalidResponse:
            "登录协议返回了无法安全处理的数据。"
        case .credentialUnavailable:
            "无法访问本机 Keychain；请解锁 Mac 后重试。"
        }
    }
}
