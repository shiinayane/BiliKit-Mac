import SwiftUI

/// 使用系统 Sidebar List 表达窗口内当前可用的平级来源。
struct AppNavigationSidebar: View {
    @Binding var selection: AppTab
    let isSignedIn: Bool
    let onPresentAuthentication: () -> Void

    var body: some View {
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Divider()
            accountButton
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.navigation")
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
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)

                Text(isSignedIn ? "账号" : "登录")

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityHint(isSignedIn ? "打开账号管理" : "打开扫码登录")
        .accessibilityIdentifier("sidebar.account")
    }
}
