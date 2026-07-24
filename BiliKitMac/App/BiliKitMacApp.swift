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
    private let uiTestConfiguration = UITestConfiguration.current
    #endif

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if uiTestConfiguration.isEnabled {
                UITestConfiguredRoot(configuration: uiTestConfiguration)
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
        #if DEBUG
        .defaultSize(
            width: uiTestConfiguration.usesCompactWindow ? 1_080 : 1_320,
            height: uiTestConfiguration.usesCompactWindow ? 680 : 820
        )
        #else
        .defaultSize(width: 1_320, height: 820)
        #endif
    }
}
