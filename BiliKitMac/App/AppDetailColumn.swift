import BiliUI
import SwiftUI

/// 右侧只渲染历史栈顶：空栈是来源根页，否则是栈顶那一页，各页不同时存在。
///
/// 必须是独立的 View 结构体并在自己的 `body` 里读 coordinator：写在 `NavigationSplitView` 的 detail 闭包里时，
/// 闭包内读到的 Observable 状态不会让 detail 列刷新。写入结果胶囊与工具栏「返回」只挂在这一层：胶囊不随页面替换而
/// 消失或重复（读屏不会把同一条结果通告两次）；「返回」只在不在根页时出现，根页时整个工具栏项不放。各页放在 `ZStack`
/// 而不是 `Group` 里：`Group` 把修饰符分发给每个分支，换页时挂在这一层的视图会随分支重建。
struct AppDetailColumn<Root: View, Playback: View>: View {
    let navigationCoordinator: AppNavigationCoordinator
    let accountWrites: AccountWriteCoordinator
    let pageTransitions: NavigationPageTransitions
    @ViewBuilder let root: () -> Root
    @ViewBuilder let playback: () -> Playback

    var body: some View {
        ZStack {
            switch navigationCoordinator.topDestination {
            case nil:
                root()
            case .playback:
                playback()
            }
        }
        .background {
            NavigationPageTransitionAnchor(transitions: pageTransitions)
        }
        .overlay(alignment: .bottom) {
            AccountWriteStatusOverlay(accountWrites: accountWrites)
        }
        .toolbar {
            if navigationCoordinator.canGoBack {
                ToolbarItem(placement: .navigation) {
                    Button(action: navigationCoordinator.goBack) {
                        Label("返回", systemImage: "chevron.backward")
                    }
                    .help(Text("返回"))
                }
            }
        }
    }
}

/// 写入结果胶囊的宿主：单独成一个 View，只有它读取协调者的结果，结果变化时不让整个外壳重新求值。
private struct AccountWriteStatusOverlay: View {
    let accountWrites: AccountWriteCoordinator

    var body: some View {
        AccountWriteStatusCapsule(
            report: accountWrites.report,
            sequence: accountWrites.reportSequence
        )
    }
}
