//
//  BiliKitMacApp.swift
//  BiliKitMac
//
//  Created by shiinayane on 2026/07/21.
//

import SwiftUI

@main
struct BiliKitMacApp: App {
    #if DEBUG
        private let usesUITestFixture = ProcessInfo.processInfo.arguments.contains(
            "-ui-testing"
        )
    #endif

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                    if usesUITestFixture {
                        UITestContentView()
                    } else {
                        AppRootView()
                    }
                #else
                    AppRootView()
                #endif
            }
            .typesettingLanguage(
                .explicit(Locale.Language(identifier: "zh-Hans"))
            )
        }
        .defaultSize(width: 1_320, height: 820)
    }
}
