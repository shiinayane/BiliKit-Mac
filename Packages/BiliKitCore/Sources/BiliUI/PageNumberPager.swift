import SwiftUI

/// 按页整体替换的列表（收藏夹）底部悬浮的玻璃页码条。
///
/// 收起时只显示“第 n / 总 页”；指针移上去展开为 `‹ 1 … 5 6 [7] 8 9 … N ›`，点数字翻页，
/// 点当前页原地输入页码跳转。指针移开、Esc 或失焦时取消输入并收起。VoiceOver 用户无法悬停，
/// 收起状态提供上下调整翻页与“输入页码跳转”操作。只拥有悬停与输入草稿；当前页、总页数与翻页意图归调用方，
/// 是否显示（总页数大于 1）也由调用方决定，列表为它留出 `PageNumberPagerGeometry.reservedHeight`。
package struct PageNumberPager: View {
    private typealias Geometry = PageNumberPagerGeometry

    private let currentPage: Int
    private let pageCount: Int
    private let onShowPage: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var isFieldFocused: Bool

    /// `onShowPage` 只收到已夹进 1…`pageCount` 且不等于当前页的页码。
    package init(currentPage: Int, pageCount: Int, onShowPage: @escaping (Int) -> Void) {
        self.currentPage = currentPage
        self.pageCount = pageCount
        self.onShowPage = onShowPage
    }

    private var isExpanded: Bool {
        isHovered || isEditing
    }

    package var body: some View {
        // 同一行里逐个插入／移除元素，宽度变化由玻璃条本身做过渡，而不是整块内容替换。
        HStack(spacing: Geometry.itemSpacing) {
            if isExpanded {
                arrow(
                    "chevron.left",
                    label: BiliUIStrings.localized("上一页", locale: locale),
                    target: currentPage - 1
                )
                .transition(expansionTransition)
                ForEach(
                    PageNumberSlots.slots(currentPage: currentPage, pageCount: pageCount),
                    id: \.self
                ) { slot in
                    switch slot {
                    case .page(let page) where page == currentPage:
                        currentPageControl
                    case .page(let page):
                        pageButton(page)
                    case .gap:
                        Text(verbatim: "…")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: Geometry.gapWidth)
                            .accessibilityHidden(true)
                    }
                }
                .transition(expansionTransition)
                arrow(
                    "chevron.right",
                    label: BiliUIStrings.localized("下一页", locale: locale),
                    target: currentPage + 1
                )
                .transition(expansionTransition)
            } else {
                collapsedLabel
                    .transition(.opacity)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Geometry.horizontalPadding)
        .padding(.vertical, Geometry.verticalPadding)
        .modifier(PageNumberPagerBackground())
        .contentShape(Capsule())
        .animation(
            reduceMotion ? nil : .snappy(duration: Geometry.expansionDuration),
            value: isExpanded
        )
        .onHover { hovering in
            isHovered = hovering
            // 移开即恢复原样：取消输入、收起。
            if !hovering { endEditing() }
        }
        .padding(.bottom, Geometry.bottomInset)
        .frame(maxWidth: .infinity)
    }

    private var expansionTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: Geometry.expansionScale))
    }

    private var pageOfTotal: String {
        BiliUIStrings.localized("第 \(currentPage) 页，共 \(pageCount) 页", locale: locale)
    }

    private var collapsedLabel: some View {
        Text(BiliUIStrings.localized("第 \(currentPage) / \(pageCount) 页", locale: locale))
            .monospacedDigit()
            .padding(.horizontal, Geometry.collapsedLabelPadding)
            .accessibilityElement()
            .accessibilityLabel(BiliUIStrings.localized("页码", locale: locale))
            .accessibilityValue(pageOfTotal)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: commit(currentPage + 1)
                case .decrement: commit(currentPage - 1)
                @unknown default: break
                }
            }
            .accessibilityAction(named: BiliUIStrings.localized("输入页码跳转", locale: locale)) {
                beginEditing()
            }
    }

    private func arrow(_ symbol: String, label: String, target: Int) -> some View {
        Button {
            commit(target)
        } label: {
            Image(systemName: symbol)
                .frame(width: Geometry.itemSize, height: Geometry.itemSize)
                .contentShape(Rectangle())
        }
        .disabled(target < 1 || target > pageCount)
        .help(label)
        .accessibilityLabel(label)
    }

    private func pageButton(_ page: Int) -> some View {
        Button {
            commit(page)
        } label: {
            pageNumber(page, isCurrent: false)
        }
        .accessibilityLabel(
            BiliUIStrings.localized("第 \(page) 页，共 \(pageCount) 页", locale: locale)
        )
    }

    @ViewBuilder
    private var currentPageControl: some View {
        if isEditing {
            TextField(BiliUIStrings.localized("页码", locale: locale), text: $editText)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .frame(width: Geometry.fieldWidth, height: Geometry.itemSize)
                .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                .focused($isFieldFocused)
                .onSubmit(submitEdit)
                .onExitCommand(perform: endEditing)
                .onChange(of: isFieldFocused) { _, focused in
                    if !focused { endEditing() }
                }
        } else {
            Button(action: beginEditing) {
                pageNumber(currentPage, isCurrent: true)
            }
            .help(BiliUIStrings.localized("输入页码跳转", locale: locale))
            .accessibilityLabel(pageOfTotal)
            .accessibilityHint(BiliUIStrings.localized("输入页码跳转", locale: locale))
            .accessibilityAddTraits(.isSelected)
        }
    }

    private func pageNumber(_ page: Int, isCurrent: Bool) -> some View {
        Text(verbatim: "\(page)")
            .monospacedDigit()
            .frame(minWidth: Geometry.itemSize, minHeight: Geometry.itemSize)
            .padding(.horizontal, Geometry.numberPadding)
            .background {
                if isCurrent {
                    Capsule().fill(Color.accentColor.opacity(0.25))
                }
            }
            .contentShape(Capsule())
    }

    private func beginEditing() {
        editText = ""
        isEditing = true
        isFieldFocused = true
    }

    private func submitEdit() {
        if let page = Int(editText.trimmingCharacters(in: .whitespaces)) {
            commit(page)
        }
        endEditing()
    }

    private func endEditing() {
        isEditing = false
        isFieldFocused = false
        editText = ""
    }

    /// 超出范围的页码修正到首页或末页；当前页不重复请求。
    private func commit(_ page: Int) {
        let clamped = min(max(1, page), pageCount)
        guard clamped != currentPage else { return }
        onShowPage(clamped)
    }
}

/// 页码条的浮动背景；macOS 26 起用玻璃。
private struct PageNumberPagerBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}
