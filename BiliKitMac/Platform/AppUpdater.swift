import Combine
import Foundation
import Sparkle

/// 进程级的 Sparkle 更新器 owner，独立于账号与窗口。
///
/// 由 `ProcessComposition` 创建并持有到进程结束；只在 `hasValidConfiguration` 通过时创建并启动 `SPUStandardUpdaterController`，把可否检查与两个自动更新开关同步给「检查更新」
/// 菜单（`AppUpdateCommands`）。不引用认证、账户或播放器，启动失败只记为 `failedToStart`，
/// 不进入其他清理链路；见 SECURITY-MODEL §7。
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    private(set) var isConfigured = false
    private(set) var failedToStart = false

    private var controller: SPUStandardUpdaterController?

    /// 开发渠道构建的 `SUFeedURL` 为空，在这里按未配置处理，菜单显示未配置。
    ///
    /// 渠道（含本机 Release 构建）由 `Configuration/BiliKit-Channel.xcconfig` 决定，只有正式渠道带 feed；
    /// 开发版因此不会按正式 appcast 检查更新。
    init() {
        guard Self.hasValidConfiguration(Bundle.main.infoDictionary ?? [:]) else { return }
        isConfigured = true
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        do {
            try controller.updater.start()
            controller.updater.publisher(for: \.canCheckForUpdates)
                .assign(to: &$canCheckForUpdates)
            controller.updater.publisher(for: \.automaticallyChecksForUpdates)
                .assign(to: &$automaticallyChecksForUpdates)
            controller.updater.publisher(for: \.automaticallyDownloadsUpdates)
                .assign(to: &$automaticallyDownloadsUpdates)
        } catch {
            // 启动失败不打断应用启动，也不暴露诊断用的 URL。
            failedToStart = true
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }

    /// Info.plist 的更新配置是否完整且符合 SECURITY-MODEL §7。
    ///
    /// 要求显式启用、HTTPS `/appcast.xml`（无 userinfo、query、fragment，端口缺省或 443）、32 字节
    /// EdDSA 公钥、签名 feed、解压前校验、签名失败不宽限、启用 Installer XPC、禁用 Downloader XPC、
    /// 关闭系统信息上报（`SUEnableSystemProfiling` 必须显式为 false，缺失同样不合规）；任一不符就不启动
    /// Sparkle。
    static func hasValidConfiguration(_ info: [String: Any]) -> Bool {
        guard info["BiliKitUpdaterEnabled"] as? Bool == true,
            let feed = info["SUFeedURL"] as? String,
            let url = URLComponents(string: feed),
            url.scheme == "https",
            let host = url.host, !host.isEmpty,
            url.user == nil, url.password == nil,
            url.query == nil, url.fragment == nil,
            url.port == nil || url.port == 443,
            url.path == "/appcast.xml",
            let key = info["SUPublicEDKey"] as? String,
            let decoded = Data(base64Encoded: key), decoded.count == 32,
            info["SUEnableInstallerLauncherService"] as? Bool == true,
            info["SUEnableDownloaderService"] as? Bool == false,
            info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
            info["SURequireSignedFeed"] as? Bool == true,
            info["SUEnableSystemProfiling"] as? Bool == false,
            info["SUSignedFeedFailureExpirationInterval"] as? Int == 0
        else { return false }
        return true
    }
}
