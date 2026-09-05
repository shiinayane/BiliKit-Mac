import SwiftUI

struct AppUpdateCommands: Commands {
    @ObservedObject var updater: AppUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if !updater.isConfigured {
                Button("检查更新（尚未配置）") {}
                    .disabled(true)
            } else if updater.failedToStart {
                Button("检查更新（暂不可用）") {}
                    .disabled(true)
            } else {
                Button("检查更新…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
                Toggle(
                    "自动检查更新",
                    isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.setAutomaticallyChecksForUpdates($0) }
                    )
                )
                Toggle(
                    "自动下载并安装更新",
                    isOn: Binding(
                        get: { updater.automaticallyDownloadsUpdates },
                        set: { updater.setAutomaticallyDownloadsUpdates($0) }
                    )
                )
                .disabled(!updater.automaticallyChecksForUpdates)
            }
        }
    }
}
