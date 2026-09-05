import Combine
import Foundation
import Sparkle

/// Owns Sparkle for the application process, independently of accounts and windows.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    private(set) var isConfigured = false
    private(set) var failedToStart = false

    private var controller: SPUStandardUpdaterController?

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        guard Self.hasValidConfiguration(info) else { return }
        isConfigured = true
        // Hosted tests must never start Sparkle's scheduler or touch update preferences.
        guard NSClassFromString("XCTestCase") == nil else { return }
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
            // Configuration errors do not interrupt app launch or expose diagnostic URLs.
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
            info["SUSignedFeedFailureExpirationInterval"] as? Int == 0
        else { return false }
        return true
    }
}
