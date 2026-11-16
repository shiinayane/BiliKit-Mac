import BiliApplication
import BiliModels
import BiliUI
import SwiftUI

/// 「设置分组…」面板（App 以 sheet 呈现）：特别关注与各自定义分组逐个一行，勾选表示这个人在这个分组里；确认后一次提交
/// 完整的分组集合，都不勾就回到默认分组。
///
/// 外形与「收藏到…」面板一致。不拥有读取与写入：底与勾选在 `FollowGroupPickerModel`，取消、重试与确认交回调用方（App 的写入
/// 协调者关闭面板、核对账户、发出写入）。勾选没变、底还没读到，或同一个人的写入在途时「完成」不可用，在途时另说明原因。
/// Esc 取消，Return 确认。
public struct FollowGroupPickerView: View {
    @Environment(\.locale) private var locale
    private let model: FollowGroupPickerModel
    private let onCancel: () -> Void
    private let onRetry: () -> Void
    private let onConfirm: () -> Void

    public init(
        model: FollowGroupPickerModel,
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
            Text(LibraryFeatureStrings.localized("设置分组", locale: locale))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding([.horizontal, .top], LibraryPanelGeometry.padding)
                .padding(.bottom, LibraryPanelGeometry.headerSpacing)
            content
                .frame(
                    minWidth: LibraryPanelGeometry.width,
                    idealWidth: LibraryPanelGeometry.width,
                    maxWidth: .infinity
                )
                .frame(height: LibraryPanelGeometry.listHeight)
            Divider()
            HStack(spacing: LibraryPanelGeometry.itemSpacing) {
                if model.isBlockedByWriteInFlight {
                    Text(
                        LibraryFeatureStrings.localized(
                            "这个人的关注正在更新，完成后才能提交。",
                            locale: locale
                        )
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(LibraryFeatureStrings.localized("取消", locale: locale), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(LibraryFeatureStrings.localized("完成", locale: locale), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.submission == nil)
            }
            .padding(LibraryPanelGeometry.padding)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView(LibraryFeatureStrings.localized("正在读取分组…", locale: locale))
                .revealsAfterLoadingDelay()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            VStack(spacing: LibraryPanelGeometry.headerSpacing) {
                Text(LibraryFeatureStrings.localized("无法读取这个人现在的分组", locale: locale))
                    .font(.headline)
                Text(
                    LibraryFeatureStrings.localized(
                        "提交会覆盖这个人的全部分组，需要先读到现在的分组。",
                        locale: locale
                    )
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                Button(LibraryFeatureStrings.localized("重试", locale: locale), action: onRetry)
            }
            .padding(LibraryPanelGeometry.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            List {
                Section {
                    ForEach(model.rows) { row in
                        Toggle(isOn: selection(row)) {
                            Text(title(row))
                        }
                        .toggleStyle(.checkbox)
                    }
                } footer: {
                    Text(LibraryFeatureStrings.localized("都不勾选时归入默认分组。", locale: locale))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func title(_ row: FollowGroupPickerModel.Row) -> String {
        row.isSpecial ? LibraryFeatureStrings.localized("特别关注", locale: locale) : row.name
    }

    private func selection(_ row: FollowGroupPickerModel.Row) -> Binding<Bool> {
        Binding(
            get: { model.isSelected(row) },
            set: { model.setSelected($0, row: row) }
        )
    }
}
