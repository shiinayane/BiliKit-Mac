import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 收藏夹来源的根视图：共用的资料库外壳（登录门槛、工具栏控件与刷新）里放夹内主区，并把页面可见性交给模型。
///
/// `.task(id:)` 在内容出现与选中的收藏夹变化时调用 `activate()` 并等待当前请求；离开来源的停用由 App 经来源描述通知，
/// 播放页只是覆盖本页面，不停用。排序菜单与工具栏尾部的搜索框由 App 宿主（`toolbarControls` 与 `.searchable`），
/// 导航标题与副标题也在 App。
public struct FavoriteFolderView: View {
    @Environment(\.locale) private var locale
    private let model: FavoriteFolderViewModel
    private let accountState: AccountPresentationState
    private let gridHost: NativeVideoGridHostContext
    private let onSelect: (String) -> Void
    private let onPresentAuthentication: () -> Void
    private let toolbarControls: AnyView

    public init(
        model: FavoriteFolderViewModel,
        accountState: AccountPresentationState,
        gridHost: NativeVideoGridHostContext,
        onSelect: @escaping (String) -> Void,
        onPresentAuthentication: @escaping () -> Void,
        toolbarControls: AnyView
    ) {
        self.model = model
        self.accountState = accountState
        self.gridHost = gridHost
        self.onSelect = onSelect
        self.onPresentAuthentication = onPresentAuthentication
        self.toolbarControls = toolbarControls
    }

    public var body: some View {
        LibrarySourceShell(
            accountState: accountState,
            signInTitle: LibraryFeatureStrings.localized("登录后查看收藏夹", locale: locale),
            signInDescription: LibraryFeatureStrings.localized(
                "收藏夹只在登录期间加载，不会保存到本机。",
                locale: locale
            ),
            onPresentAuthentication: onPresentAuthentication,
            toolbarControls: toolbarControls,
            isBusy: { model.isBusy },
            refresh: model.reload,
            content: {
                FavoriteFolderContentView(model: model, gridHost: gridHost, onSelect: onSelect)
                    .task(id: model.selectedFolderID) {
                        model.activate()
                        await model.waitForCurrentTask()
                    }
            }
        )
    }
}

/// 侧栏「收藏夹」组：可折叠的分段，每个自己创建的收藏夹一行；列表加载中、失败与账户未知时各显示一行说明。
///
/// 每行用调用方给的 `tag(id)` 作选择值，行图标统一是 `folder`；私密收藏夹在名称右边紧跟一个次要颜色的小锁（名称
/// 过长时截断名称、锁仍可见；读屏不读图标，改在行的值里读“私密”），默认收藏夹不特殊标记，数量不在行上显示。说明行
/// 不可选中：失败行是重试按钮，账户未知只说明、不给重试。不拥有列表与折叠状态：列表归 `FavoriteFolderListModel`（由 App 按窗口账户范围触发读取），
/// 折叠只在窗口内存里、由 App 持有。
public struct FavoriteFolderSidebarSection<Tag: Hashable>: View {
    @Environment(\.locale) private var locale
    private let model: FavoriteFolderListModel
    private let title: LocalizedStringResource
    @Binding private var isExpanded: Bool
    private let tag: (Int64) -> Tag

    public init(
        model: FavoriteFolderListModel,
        title: LocalizedStringResource,
        isExpanded: Binding<Bool>,
        tag: @escaping (Int64) -> Tag
    ) {
        self.model = model
        self.title = title
        _isExpanded = isExpanded
        self.tag = tag
    }

    public var body: some View {
        Section(isExpanded: $isExpanded) {
            switch model.state {
            case .loaded(let folders):
                ForEach(folders) { folder in
                    row(folder)
                        .tag(tag(folder.id))
                }
            case .idle, .loading:
                loadingRow
            case .failed where model.isAwaitingAuthenticationRevalidation:
                loadingRow
            case .failed:
                Button(action: model.reload) {
                    Label {
                        Text(LibraryFeatureStrings.localized("无法加载收藏夹", locale: locale))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .selectionDisabled()
                .help(LibraryFeatureStrings.localized("重新加载收藏夹", locale: locale))
                .accessibilityHint(LibraryFeatureStrings.localized("重新加载收藏夹", locale: locale))
            case .accountUnidentified:
                Label {
                    Text(LibraryFeatureStrings.localized("无法确认当前账户", locale: locale))
                } icon: {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                }
                .foregroundStyle(.secondary)
                .selectionDisabled()
                .help(
                    LibraryFeatureStrings.localized(
                        "重新确认登录状态或重新登录后可查看收藏夹。",
                        locale: locale
                    )
                )
            }
        } header: {
            Text(title)
        }
    }

    private func row(_ folder: FavoriteFolder) -> some View {
        Label {
            FavoriteFolderTitle(folder: folder)
        } icon: {
            Image(systemName: "folder")
        }
        .accessibilityValue(
            folder.isPrivate ? LibraryFeatureStrings.localized("私密", locale: locale) : ""
        )
    }

    private var loadingRow: some View {
        Label {
            Text(LibraryFeatureStrings.localized("正在加载收藏夹…", locale: locale))
        } icon: {
            ProgressView()
                .controlSize(.small)
        }
        .foregroundStyle(.secondary)
        .revealsAfterLoadingDelay()
        .selectionDisabled()
    }
}

/// 收藏夹名称与私密锁，侧栏的行与「收藏到…」面板共用。
///
/// 锁紧跟在名称右边，名称过长时截断名称，锁固定尺寸、优先级更高，始终可见。锁对读屏隐藏，“私密”由使用处读给读屏
/// （侧栏放进行的值，面板的勾选框放进标签）。
struct FavoriteFolderTitle: View {
    /// 私密锁与名称之间的间距。
    private static let titleLockSpacing: CGFloat = 4

    let folder: FavoriteFolder

    var body: some View {
        HStack(spacing: Self.titleLockSpacing) {
            Text(folder.title)
                .lineLimit(1)
                .truncationMode(.tail)
            if folder.isPrivate {
                Image(systemName: "lock.fill")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .layoutPriority(1)
                    .accessibilityHidden(true)
            }
        }
    }
}
