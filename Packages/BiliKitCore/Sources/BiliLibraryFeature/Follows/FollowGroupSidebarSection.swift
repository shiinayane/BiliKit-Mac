import BiliApplication
import BiliModels
import SwiftUI

/// 侧栏「关注」组：可折叠的分段，「全部关注」一行在最前，其后按侧栏顺序每个分组一行，各带人数。
///
/// 每行用调用方给的 `tag(id)` 作选择值（「全部关注」是 `FollowListSession.allFollowingsRowID`）。特别关注的图标是星，其余
/// 分组是标签；特别关注与默认分组的名字按 id 本地化，不用接口给的中文名。人数在行尾、读屏作为行的值。分组读取中、失败或
/// 账户未知时只留「全部关注」：失败时在组标题旁给重试按钮（不把失败做成一行，「全部关注」仍可用），账户未知只说明、不给
/// 重试。不拥有分组列表与折叠状态：列表归 `FollowGroupListModel`（由 App 按窗口账户范围触发读取），折叠由 App 持有。
public struct FollowGroupSidebarSection<Tag: Hashable>: View {
    @Environment(\.locale) private var locale
    private let model: FollowGroupListModel
    private let title: LocalizedStringResource
    @Binding private var isExpanded: Bool
    private let tag: (Int64) -> Tag

    public init(
        model: FollowGroupListModel,
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
            row(
                title: LibraryFeatureStrings.localized("全部关注", locale: locale),
                systemImage: "person.2",
                count: model.loadedValue?.totalCount
            )
            .tag(tag(FollowListSession.allFollowingsRowID))
            ForEach(model.groups) { group in
                row(
                    title: group.displayName(locale: locale),
                    systemImage: icon(of: group),
                    count: group.count
                )
                .tag(tag(group.id))
            }
            if case .accountUnidentified = model.state {
                Label {
                    Text(LibraryFeatureStrings.localized("无法确认当前账户", locale: locale))
                } icon: {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                }
                .foregroundStyle(.secondary)
                .selectionDisabled()
                .help(
                    LibraryFeatureStrings.localized(
                        "重新确认登录状态或重新登录后可查看关注分组。",
                        locale: locale
                    )
                )
            }
        } header: {
            header
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(title)
            if showsRetry {
                Button(action: model.reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(LibraryFeatureStrings.localized("重新加载关注分组", locale: locale))
                .accessibilityLabel(LibraryFeatureStrings.localized("重新加载关注分组", locale: locale))
            }
        }
    }

    private var showsRetry: Bool {
        guard case .failed = model.state else { return false }
        return !model.isAwaitingAuthenticationRevalidation
    }

    private func row(title: String, systemImage: String, count: Int?) -> some View {
        LibrarySidebarCountRow(systemImage: systemImage, count: count) {
            Text(title)
                .lineLimit(1)
        }
    }

    private func icon(of group: FollowGroup) -> String {
        group.kind == .special ? "star" : "tag"
    }
}

extension FollowGroup {
    /// 侧栏行与导航标题共用的名字：特别关注与默认分组按 id 本地化，自定义分组用接口给的名字。
    func displayName(locale: Locale) -> String {
        switch kind {
        case .special: LibraryFeatureStrings.localized("特别关注", locale: locale)
        case .default: LibraryFeatureStrings.localized("默认分组", locale: locale)
        case .custom: name
        }
    }
}

extension FollowListSession {
    /// 选中行的标题：「全部关注」或分组名；选中的分组还不在已加载的列表里时为 nil，由调用方用来源标题。
    public func selectedRowTitle(groupList: FollowGroupListModel, locale: Locale) -> String? {
        if isShowingAllFollowings {
            return LibraryFeatureStrings.localized("全部关注", locale: locale)
        }
        return groupList.groups.first { $0.id == selectedRowID }?.displayName(locale: locale)
    }
}
