import BiliAuthFeature
import SwiftUI

/// 使用系统 Sidebar List 表达窗口内当前可用的平级来源。
struct AppNavigationSidebar: View {
    @Binding var selection: AppTab
    let accountState: AccountPresentationState
    let onPresentAuthentication: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            navigationList
            accountBar
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.navigation")
    }

    private var navigationList: some View {
        List(selection: selectionBinding) {
            Label("搜索", systemImage: "magnifyingglass")
                .tag(AppTab.search)
                .accessibilityIdentifier("sidebar.search")

            Label("热门", systemImage: "flame")
                .tag(AppTab.popular)
                .accessibilityIdentifier("sidebar.popular")

            Label("观看历史", systemImage: "clock.arrow.circlepath")
                .tag(AppTab.history)
                .accessibilityIdentifier("sidebar.history")
        }
        .listStyle(.sidebar)
    }

    private var accountBar: some View {
        accountButton
    }

    private var selectionBinding: Binding<AppTab?> {
        Binding(
            get: { selection },
            set: { newValue in
                guard let newValue else { return }
                selection = newValue
            }
        )
    }

    private var accountButton: some View {
        Button(action: onPresentAuthentication) {
            HStack(spacing: 12) {
                accountAvatar

                Text(accountTitle)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityHint(accountAccessibilityHint)
        .accessibilityIdentifier("sidebar.account")
    }

    private var accountTitle: String {
        switch accountState {
        case .resolving, .unavailable:
            "账号"
        case .signedOut:
            "登录"
        case .signedIn:
            "账号"
        }
    }

    private var accountAccessibilityHint: String {
        switch accountState {
        case .resolving:
            "正在检查本机登录状态"
        case .unavailable:
            "打开账号以重试恢复"
        case .signedOut:
            "打开扫码登录"
        case .signedIn:
            "打开账号管理"
        }
    }

    private var accountAvatar: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.hierarchical)
            .frame(width: 32, height: 32)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}
