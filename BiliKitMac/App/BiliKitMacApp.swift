//
//  BiliKitMacApp.swift
//  BiliKitMac
//
//  Created by shiinayane on 2026/07/21.
//

import SwiftUI

@main
struct BiliKitMacApp: App {
    @State private var accountSessionCoordinator: AccountSessionCoordinator
    @State private var systemNowPlayingController = SystemNowPlayingController()
    @State private var appSettingsModel: AppSettingsModel

    init() {
        let accountSessionCoordinator = AccountSessionCoordinator()
        AppEnvironment.prepareLiveWatchProgressRepository(
            accountSessionCoordinator: accountSessionCoordinator
        )
        _accountSessionCoordinator = State(initialValue: accountSessionCoordinator)
        _appSettingsModel = State(
            initialValue: AppEnvironment.liveAppSettingsModel(
                accountSessionCoordinator: accountSessionCoordinator
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(
                accountSessionCoordinator: accountSessionCoordinator,
                systemNowPlayingController: systemNowPlayingController,
                appSettingsModel: appSettingsModel
            )
        }
        .defaultSize(width: 1_320, height: 820)

        Settings {
            PlaybackSourceSettingsView(model: appSettingsModel)
        }
    }
}
