import BiliApplication
import BiliModels
import BiliUI
import SwiftUI

/// 搜索起始页的几何：内容宽度、分区间距、历史词胶囊与热搜行。
enum SearchStartLayout {
    static let maximumContentWidth: CGFloat = 760
    static let contentPadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 28
    static let headerSpacing: CGFloat = 12
    static let historyChipSpacing: CGFloat = 8
    static let historyChipMaximumWidth: CGFloat = 240
    static let inlineSpacing: CGFloat = 8
    static let trendingColumnCount = 2
    static let trendingColumnSpacing: CGFloat = 24
    static let trendingRowSpacing: CGFloat = 4
    static let trendingRowVerticalPadding: CGFloat = 6
    static let trendingRankWidth: CGFloat = 22
    static let trendingIconHeight: CGFloat = 14
    /// 前几名的序号用强调色。
    static let highlightedRankCount = 3
}

/// 搜索起始页的输入，由 App 构造；整体为 nil 时起始页留空，所以没有热搜模型就不会有图标 loader。
///
/// 历史由 App 层的进程级 store 持有：`history` 是读取闭包，只在起始页的 body 里调用，历史变化只让起始页
/// 重算，不牵动搜索页其余部分与工具栏。点选历史或热搜词经 `onSearch` 交给 App 走提交搜索的同一路径。
public struct SearchStartPageContext {
    let trendingModel: TrendingSearchViewModel
    let iconLoader: any TrendingSearchIconLoading
    let history: () -> [String]
    let onSearch: (String) -> Void
    let onRemoveHistory: (String) -> Void
    let onClearHistory: () -> Void

    public init(
        trendingModel: TrendingSearchViewModel,
        iconLoader: any TrendingSearchIconLoading,
        history: @escaping () -> [String],
        onSearch: @escaping (String) -> Void,
        onRemoveHistory: @escaping (String) -> Void,
        onClearHistory: @escaping () -> Void
    ) {
        self.trendingModel = trendingModel
        self.iconLoader = iconLoader
        self.history = history
        self.onSearch = onSearch
        self.onRemoveHistory = onRemoveHistory
        self.onClearHistory = onClearHistory
    }
}

/// 未提交搜索时的起始页：本机搜索历史与 B 站热搜，点选任一词即发起搜索。
///
/// 只接收 `SearchStartPageContext` 给的值与意图回调；热搜状态归 `TrendingSearchViewModel`，图标经 App 注入的
/// `TrendingSearchIconLoading` 加载。
struct SearchStartView: View {
    @Environment(\.locale) private var locale
    let context: SearchStartPageContext

    var body: some View {
        let history = context.history()
        ScrollView {
            VStack(alignment: .leading, spacing: SearchStartLayout.sectionSpacing) {
                if !history.isEmpty {
                    historySection(history)
                }
                trendingSection
            }
            .frame(maxWidth: SearchStartLayout.maximumContentWidth, alignment: .leading)
            .padding(SearchStartLayout.contentPadding)
            .frame(maxWidth: .infinity)
        }
        .task {
            context.trendingModel.refresh()
        }
    }

    private func historySection(_ history: [String]) -> some View {
        VStack(alignment: .leading, spacing: SearchStartLayout.headerSpacing) {
            HStack {
                sectionHeader(BrowseFeatureStrings.localized("搜索历史", locale: locale))
                Spacer()
                Button(
                    BrowseFeatureStrings.localized("清除", locale: locale),
                    action: context.onClearHistory
                )
                .buttonStyle(.link)
                .accessibilityLabel(
                    BrowseFeatureStrings.localized("清除搜索历史", locale: locale)
                )
            }
            SearchHistoryFlowLayout(spacing: SearchStartLayout.historyChipSpacing) {
                ForEach(history, id: \.self) { query in
                    historyChip(query)
                }
            }
        }
    }

    /// 历史词是系统胶囊按钮：按下高亮、全键盘访问的焦点环与增强对比度下的边框都由系统给。
    ///
    /// macOS 26 起也不用玻璃样式：胶囊在内容层里，玻璃留给浮在内容之上的控件（例如评论图片预览的按钮）。
    private func historyChip(_ query: String) -> some View {
        let removeTitle = BrowseFeatureStrings.localized("删除", locale: locale)
        return Button {
            context.onSearch(query)
        } label: {
            Text(query)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: SearchStartLayout.historyChipMaximumWidth)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .help(query)
        .contextMenu {
            Button(removeTitle, role: .destructive) {
                context.onRemoveHistory(query)
            }
        }
        .accessibilityAction(named: removeTitle) {
            context.onRemoveHistory(query)
        }
    }

    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: SearchStartLayout.headerSpacing) {
            sectionHeader(BrowseFeatureStrings.localized("B 站热搜", locale: locale))
            trendingContent
        }
    }

    @ViewBuilder
    private var trendingContent: some View {
        switch context.trendingModel.state {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(
                    BrowseFeatureStrings.localized("正在加载热搜", locale: locale)
                )
                .revealsAfterLoadingDelay()
        case .failed(let error):
            HStack(spacing: SearchStartLayout.inlineSpacing) {
                Text(ContentFailureText.message(for: error, locale: locale))
                    .foregroundStyle(.secondary)
                Button(BrowseFeatureStrings.localized("重试", locale: locale)) {
                    context.trendingModel.refresh()
                }
            }
        case .loaded(let keywords) where keywords.isEmpty:
            Text(BrowseFeatureStrings.localized("暂时没有热搜", locale: locale))
                .foregroundStyle(.secondary)
        case .loaded(let keywords):
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(
                        .flexible(),
                        spacing: SearchStartLayout.trendingColumnSpacing,
                        alignment: .leading
                    ),
                    count: SearchStartLayout.trendingColumnCount
                ),
                alignment: .leading,
                spacing: SearchStartLayout.trendingRowSpacing
            ) {
                ForEach(Array(keywords.enumerated()), id: \.element.keyword) { index, keyword in
                    trendingRow(rank: index + 1, keyword: keyword)
                }
            }
        }
    }

    private func trendingRow(rank: Int, keyword: TrendingSearchKeyword) -> some View {
        Button {
            context.onSearch(keyword.keyword)
        } label: {
            HStack(spacing: SearchStartLayout.inlineSpacing) {
                Text(rank, format: .number)
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundStyle(
                        rank <= SearchStartLayout.highlightedRankCount
                            ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
                    )
                    .frame(width: SearchStartLayout.trendingRankWidth, alignment: .trailing)
                Text(keyword.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let iconURL = keyword.iconURL {
                    TrendingSearchIconView(url: iconURL, iconLoader: context.iconLoader)
                        .frame(height: SearchStartLayout.trendingIconHeight)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, SearchStartLayout.trendingRowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(keyword.displayName)
        .accessibilityLabel(
            BrowseFeatureStrings.localized(
                "第 \(rank) 名，\(keyword.displayName)",
                locale: locale
            )
        )
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 历史词胶囊按行排布，放不下时换行；行内左对齐。
struct SearchHistoryFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, maximumWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        // 与测量用同一个宽度换行，避免最终宽度的舍入改变换行位置。
        let maximumWidth = proposal.width ?? bounds.width
        for row in arrange(subviews: subviews, maximumWidth: maximumWidth) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    /// 一行排布结果：成员的下标与测得尺寸，以及累计宽度与行高。
    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// 测量与放置共用同一次排布计算。
    private func arrange(subviews: Subviews, maximumWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            // 胶囊按文字的理想宽度排布；只有比整行还宽时才收窄到行宽。
            let idealSize = subviews[index].sizeThatFits(.unspecified)
            let size =
                idealSize.width <= maximumWidth
                ? idealSize
                : subviews[index].sizeThatFits(ProposedViewSize(width: maximumWidth, height: nil))
            let proposedWidth =
                current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty, proposedWidth > maximumWidth {
                rows.append(current)
                current = Row()
            }
            current.width =
                current.items.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.items.append((index, size))
        }
        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
