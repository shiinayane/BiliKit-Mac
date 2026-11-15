//
//  BiliKitMacApp.swift
//  BiliKitMac
//
//  Created by shiinayane on 2026/07/21.
//

import SwiftUI

/// App 入口：持有进程唯一的 `ProcessComposition`，声明主窗口组与设置窗口两个 scene。
///
/// 每个主窗口由 `AppRootView` 经 `makeWindow()` 组装自己的对象图；
/// 设置窗口与菜单命令直接使用进程级的设置模型与更新器。
@main
struct BiliKitMacApp: App {
    /// 进程级组装只构造一次；每个窗口由 `AppRootView` 从它组装一次自己的对象图。
    @State private var process = ProcessComposition.live()

    var body: some Scene {
        WindowGroup {
            AppRootView(window: process.makeWindow())
        }
        .defaultSize(width: 1_320, height: 820)
        .commands {
            AppUpdateCommands(updater: process.updater)
            AppNavigationCommands()
        }

        Settings {
            PlaybackSourceSettingsView(model: process.settings)
        }
    }
}
