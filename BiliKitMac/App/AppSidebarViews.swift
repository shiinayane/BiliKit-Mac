import BiliApplication
import BiliAuthFeature
import BiliLibraryFeature
import SwiftUI

/// 使用系统 Sidebar List 表达窗口内当前可用的平级来源；按 `AppSources` 的分段渲染 `Section`，带标题的组显示
/// 分段标题，行按段内顺序与描述渲染。
///
/// 选择值是 `AppSidebarSelection`，读写由 `AppShellView` 经 `AppSources` 映射到
/// 导航协调器。「收藏夹」组只在已登录时显示，由 Library 的 `FavoriteFolderSidebarSection` 渲染每个收藏夹一行
/// （tag 为 `.item(.favorites, id:)`），折叠状态由 `AppShellView` 持有；侧栏出现与窗口账户范围变化时让收藏夹列表按
/// 账户范围对齐（未解析到已登录不算账户变化，首次读取只能由这里触发）。
///
/// 底部账号行的头像经窗口图片管线加载（`AccountAvatarImage`），不拥有管线。
struct AppNavigationSidebar: View {
    let sections: [AppSourceSection]
    @Binding var selection: AppSidebarSelection
    let favoriteFolderList: FavoriteFolderListModel
    @Binding var isFavoritesExpanded: Bool
    let accountScope: AccountSessionScope
    let accountState: AccountPresentationState
    let imagePipeline: NativeVideoImagePipeline
    let onPresentAuthentication: () -> Void

    var body: some View {
        sidebarContent
            .task(id: accountScope) {
                favoriteFolderList.synchronize()
            }
    }

    /// 账号行钉在侧栏底部；macOS 26 起挂成列表的 `safeAreaBar`，列表从它下方滚过，由系统滚动边缘效果垫底。
    ///
    /// macOS 15 没有滚动边缘效果，`safeAreaInset` 会让滚过的行透出账号行，所以仍与列表上下并列、不重叠。
    @ViewBuilder
    private var sidebarContent: some View {
        if #available(macOS 26, *) {
            navigationList
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    accountBar
                }
        } else {
            VStack(spacing: 0) {
                navigationList
                accountBar
            }
        }
    }

    private var navigationList: some View {
        List(selection: selectionBinding) {
            ForEach(visibleSections) { section in
                switch section.group {
                case .browse, .library:
                    if let title = section.group.title {
                        Section {
                            rows(section.sources)
                        } header: {
                            Text(title)
                        }
                    } else {
                        Section {
                            rows(section.sources)
                        }
                    }
                case .favorites:
                    // 「收藏夹」组总有标题。
                    if let title = section.group.title {
                        FavoriteFolderSidebarSection(
                            model: favoriteFolderList,
                            title: title,
                            isExpanded: $isFavoritesExpanded,
                            tag: { AppSidebarSelection.item(.favorites, id: $0) }
                        )
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// 未登录（含仍在确认、无法确认）时不显示只在登录后才有行的组。
    private var visibleSections: [AppSourceSection] {
        guard case .signedIn = accountState else {
            return sections.filter { !$0.group.isShownOnlyWhenSignedIn }
        }
        return sections
    }

    private func rows(_ sources: [AppSourceDescriptor]) -> some View {
        ForEach(sources) { source in
            Label {
                Text(source.title)
            } icon: {
                Image(systemName: source.systemImage)
            }
            .tag(AppSidebarSelection.source(source.id))
        }
    }

    private var accountBar: some View {
        accountButton
    }

    private var selectionBinding: Binding<AppSidebarSelection?> {
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
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityHint(accountAccessibilityHint)
    }

    private var accountTitle: String {
        switch accountState {
        case .resolving, .unavailable:
            AppStrings.localized("账号")
        case .signedOut:
            AppStrings.localized("登录")
        case .signedIn:
            accountState.displayName ?? AppStrings.localized("账号")
        }
    }

    private var accountAccessibilityHint: String {
        switch accountState {
        case .resolving:
            AppStrings.localized("正在检查本机登录状态")
        case .unavailable:
            AppStrings.localized("打开账号以重试恢复")
        case .signedOut:
            AppStrings.localized("打开扫码登录")
        case .signedIn:
            AppStrings.localized("打开账号管理")
        }
    }

    private var accountAvatar: some View {
        Group {
            if let requestURL = NativeVideoImagePipeline.accountAvatarRequestURL(
                for: accountState.avatarURL
            ) {
                AccountAvatarImage(requestURL: requestURL, imagePipeline: imagePipeline) {
                    fallbackAvatar
                }
            } else {
                fallbackAvatar
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var fallbackAvatar: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.hierarchical)
    }
}
