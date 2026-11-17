import BiliUI
import SwiftUI

/// 右侧只渲染历史栈顶：空栈是来源根页，否则是栈顶那一页（播放页或整页空间页），各页不同时存在。
///
/// 必须是独立的 View 结构体并在自己的 `body` 里读 coordinator：写在 `NavigationSplitView` 的 detail 闭包里时，
/// 闭包内读到的 Observable 状态不会让 detail 列刷新。写入结果胶囊与工具栏「返回｜回到「来源名」」只挂在这一层：胶囊
/// 不随页面替换而消失或重复（读屏不会把同一条结果通告两次）；这组按钮只在不在根页时出现，根页时整个工具栏项不放（理由
/// 见 docs/ARCHITECTURE.md「播放页布局」）。各页放在 `ZStack` 而不是 `Group` 里：`Group` 把修饰符分发给每个分支，
/// 换页时挂在这一层的视图会随分支重建。
struct AppDetailColumn<Root: View, Playback: View, Space: View>: View {
    let navigationCoordinator: AppNavigationCoordinator
    let accountWrites: AccountWriteCoordinator
    let pageTransitions: NavigationPageTransitions
    /// 当前来源的名字，⌂ 的标题见 `Text(goingBackTo:)`。
    let rootTitle: LocalizedStringResource
    @ViewBuilder let root: () -> Root
    @ViewBuilder let playback: () -> Playback
    @ViewBuilder let space: () -> Space
    /// 栈顶页面底部分页胶囊的高度，写入结果胶囊据此避开它。
    @State private var paginationLaneHeight: CGFloat = 0

    var body: some View {
        ZStack {
            switch navigationCoordinator.topDestination {
            case nil:
                root()
            case .playback:
                playback()
            case .uploaderSpace:
                space()
            }
        }
        .onPreferenceChange(PaginationStatusLaneHeightKey.self) { height in
            paginationLaneHeight = height
        }
        .background {
            NavigationPageTransitionAnchor(transitions: pageTransitions)
        }
        .overlay(alignment: .bottom) {
            AccountWriteStatusOverlay(
                accountWrites: accountWrites,
                bottomClearance: paginationLaneHeight
            )
        }
        .toolbar {
            if navigationCoordinator.canGoBack {
                ToolbarItem(placement: .navigation) {
                    ControlGroup {
                        Button(action: navigationCoordinator.goBack) {
                            Label("返回", systemImage: "chevron.backward")
                        }
                        .help(Text("返回"))
                        Button(action: navigationCoordinator.goHome) {
                            Label {
                                Text(goingBackTo: rootTitle)
                            } icon: {
                                Image(systemName: "house")
                            }
                        }
                        .help(Text(goingBackTo: rootTitle))
                    }
                    // 不加这个样式时，控件组会被排到工具栏右侧，而不是标题左边。
                    .controlGroupStyle(.navigation)
                }
            }
        }
    }
}

extension Text {
    /// 「回到「来源名」」：工具栏的 ⌂ 与菜单栏共用；不叫“回到首页”，侧栏有一个来源就叫「首页」。
    init(goingBackTo rootTitle: LocalizedStringResource) {
        self.init("回到「\(String(localized: rootTitle))」")
    }
}

/// 写入结果胶囊的宿主：单独成一个 View，只有它读取协调者的结果，结果变化时不让整个外壳重新求值。
private struct AccountWriteStatusOverlay: View {
    let accountWrites: AccountWriteCoordinator
    let bottomClearance: CGFloat

    var body: some View {
        AccountWriteStatusCapsule(
            report: accountWrites.windowReport,
            sequence: accountWrites.reportSequence,
            bottomClearance: bottomClearance
        )
    }
}
