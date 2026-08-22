//
//  BiliKitMacApp.swift
//  BiliKitMac
//
//  Created by shiinayane on 2026/07/21.
//

import SwiftUI

@main
struct BiliKitMacApp: App {
    @State private var accountSessionCoordinator = AccountSessionCoordinator()
    @State private var systemNowPlayingController = SystemNowPlayingController()
    @State private var appSettingsModel = AppSettingsModel.live()

    var body: some Scene {
        WindowGroup {
            AppRootView(
                accountSessionCoordinator: accountSessionCoordinator,
                systemNowPlayingController: systemNowPlayingController,
                appSettingsModel: appSettingsModel
            )
            .typesettingLanguage(
                .explicit(Locale.Language(identifier: "zh-Hans"))
            )
        }
        .defaultSize(width: 1_320, height: 820)

        Settings {
            PlaybackSourceSettingsView(model: appSettingsModel)
        }
    }
}
