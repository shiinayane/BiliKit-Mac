import SwiftUI

/// 「前往」菜单读到的当前窗口导航：协调器、当前来源的名字与两项动作此刻能不能用。
///
/// 由 `AppShellView` 经 `focusedSceneValue` 交出：第一响应者是集合视图或播放器（AppKit）时，视图级的 `focusedValue` 读不到，
/// 菜单会一直灰着；按场景取就只看哪个窗口在前。能不能用作为值交出，而不是让菜单去读协调器：`AppShellView` 求值时读到
/// 它们，历史一变就交出新值，菜单项随之更新。
struct AppNavigationMenuTarget: Equatable {
    let coordinator: AppNavigationCoordinator
    let rootTitle: LocalizedStringResource
    let canNavigateBack: Bool
    let canGoHome: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.coordinator === rhs.coordinator && lhs.rootTitle == rhs.rootTitle
            && lhs.canNavigateBack == rhs.canNavigateBack && lhs.canGoHome == rhs.canGoHome
    }
}

extension FocusedValues {
    @Entry var appNavigation: AppNavigationMenuTarget?
}

/// 菜单栏的「前往」菜单：「返回」（⌘[，预览开着时先关预览）与「回到「来源名」」（⇧⌘H），与工具栏的返回控件同一组动作。
///
/// 只读取前面那个窗口交出的协调器（`AppNavigationMenuTarget`）；没有窗口或不能动作时菜单项灰着。评论图片预览面板、
/// sheet 在前时没有交出的值，菜单项灰着；在文本框里输入时 ⌘[ 同样返回（与浏览器一致），评论与弹幕的草稿归窗口，不随
/// 页面丢失。
struct AppNavigationCommands: Commands {
    @FocusedValue(\.appNavigation) private var target

    var body: some Commands {
        CommandMenu("前往") {
            Button("返回") { target?.coordinator.navigateBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(target?.canNavigateBack ?? false))
            // 没有前面的窗口时项灰着，名字随便取一个来源的。
            Button {
                target?.coordinator.goHome()
            } label: {
                Text(goingBackTo: target?.rootTitle ?? "首页")
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(!(target?.canGoHome ?? false))
        }
    }
}
