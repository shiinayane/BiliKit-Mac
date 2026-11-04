import BiliApplication
import BiliModels
import BiliUI
import SwiftUI

/// 「收藏到…」面板（App 以 sheet 呈现）：自己的收藏夹逐个一行，顺序、名称与私密锁同侧栏，另显示条数；勾选表示视频在
/// 这个夹里，确认后一次提交勾选与初始归属的差异。
///
/// 不拥有读取与写入：归属与勾选在 `FavoritePickerModel`，取消、重试与确认交回调用方（App 的写入协调者关闭面板、核对账户、
/// 发出写入）。
/// 没有改动时确认禁用；第一版不提供新建收藏夹。Esc 取消，Return 确认。
public struct FavoritePickerView: View {
    @Environment(\.locale) private var locale
    private let model: FavoritePickerModel
    private let onCancel: () -> Void
    private let onRetry: () -> Void
    private let onConfirm: () -> Void

    public init(
        model: FavoritePickerModel,
        onCancel: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.model = model
        self.onCancel = onCancel
        self.onRetry = onRetry
        self.onConfirm = onConfirm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(LibraryFeatureStrings.localized("收藏到", locale: locale))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding([.horizontal, .top], FavoritePickerGeometry.padding)
                .padding(.bottom, FavoritePickerGeometry.headerSpacing)
            // 宽度只给下限与理想值：sheet 可能比理想宽度宽（系统的最小宽度），列表要跟着撑满，不能固定宽度靠左。
            content
                .frame(
                    minWidth: FavoritePickerGeometry.width,
                    idealWidth: FavoritePickerGeometry.width,
                    maxWidth: .infinity
                )
                .frame(height: FavoritePickerGeometry.listHeight)
            Divider()
            HStack {
                Spacer()
                Button(LibraryFeatureStrings.localized("取消", locale: locale), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(LibraryFeatureStrings.localized("完成", locale: locale), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.change == nil)
            }
            .padding(FavoritePickerGeometry.padding)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView(LibraryFeatureStrings.localized("正在加载收藏夹…", locale: locale))
                .revealsAfterLoadingDelay()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            LibraryContentFailure(isAwaitingRevalidation: false, locale: locale)
                .view(
                    error,
                    fallbackTitle: LibraryFeatureStrings.localized("无法加载收藏夹", locale: locale),
                    retry: onRetry
                )
        case .loaded(let memberships):
            List(memberships) { membership in
                // 条数放在勾选框外：勾选框的标签按内容宽度排版，里面的 Spacer 撑不开行宽，条数会紧跟名称。
                HStack {
                    Toggle(isOn: selection(membership.id)) {
                        FavoriteFolderTitle(folder: membership.folder)
                    }
                    .toggleStyle(.checkbox)
                    // 私密与条数放进标签而不是值：勾选框的值是勾选状态，覆盖掉读屏就读不出是否已勾选；条数单独成元素
                    // 时读屏只读出一个没有上下文的数字。
                    .accessibilityLabel(accessibilityLabel(membership.folder))
                    Spacer(minLength: FavoritePickerGeometry.countSpacing)
                    Text(formattedCount(membership.folder))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func formattedCount(_ folder: FavoriteFolder) -> String {
        folder.mediaCount.formatted(.number.locale(InterfaceLocale.current))
    }

    private func accessibilityLabel(_ folder: FavoriteFolder) -> String {
        let count = formattedCount(folder)
        return folder.isPrivate
            ? LibraryFeatureStrings.localized("\(folder.title)（私密），\(count) 个内容", locale: locale)
            : LibraryFeatureStrings.localized("\(folder.title)，\(count) 个内容", locale: locale)
    }

    private func selection(_ folderID: Int64) -> Binding<Bool> {
        Binding(
            get: { model.selectedFolderIDs.contains(folderID) },
            set: { model.setSelected($0, folderID: folderID) }
        )
    }
}

/// 「收藏到…」面板的几何。
private enum FavoritePickerGeometry {
    static let width: CGFloat = 360
    /// 列表区固定高度：约十行，夹再多就在列表内滚动，面板尺寸不随读取状态跳动。
    static let listHeight: CGFloat = 320
    static let padding: CGFloat = 16
    static let headerSpacing: CGFloat = 8
    static let countSpacing: CGFloat = 12
}
