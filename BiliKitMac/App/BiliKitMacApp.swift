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

    var body: some Scene {
        WindowGroup {
            AppRootView(accountSessionCoordinator: accountSessionCoordinator)
                .typesettingLanguage(
                    .explicit(Locale.Language(identifier: "zh-Hans"))
                )
        }
        .defaultSize(width: 1_320, height: 820)
    }
}
