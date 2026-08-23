import BiliBrowseFeature
import Foundation
import SwiftUI

struct AppliedVideoSearchFilters: Hashable {
    var order: VideoSearchOrder = .relevance
    var duration: VideoDurationFilter = .all
    var publicationRange: VideoPublicationTimeRange?

    func criteria(query: String) -> VideoSearchCriteria {
        VideoSearchCriteria(
            query: query,
            order: order,
            duration: duration,
            publicationRange: publicationRange
        )
    }
}

struct SearchFilterSelection: Hashable {
    var order: VideoSearchOrder = .relevance
    var publication = VideoPublicationFilter.all
    var duration = VideoDurationFilter.all
    var customStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    var customEnd = Date()

    var activeFilterCount: Int {
        (publication == .all ? 0 : 1) + (duration == .all ? 0 : 1)
    }

    mutating func resetFilters() {
        publication = .all
        duration = .all
    }

    func resolvedFilters(
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> AppliedVideoSearchFilters {
        AppliedVideoSearchFilters(
            order: order,
            duration: duration,
            publicationRange: try VideoPublicationRangeResolver.resolve(
                filter: publication,
                customStart: customStart,
                customEnd: customEnd,
                now: now,
                calendar: calendar
            )
        )
    }

    func summary(locale: Locale) -> String {
        ListFormatter.localizedString(
            byJoining: [
                publication == .all ? nil : publication.localizedTitle(locale: locale),
                duration == .all ? nil : duration.localizedTitle(locale: locale),
            ].compactMap { $0 }
        )
    }
}

struct SearchToolbarControls: View {
    @Environment(\.locale) private var locale
    @Binding var selection: SearchFilterSelection
    @State private var draft = SearchFilterSelection()
    @State private var isFilterPopoverPresented = false

    let onSelectOrder: (VideoSearchOrder) -> Void
    let onApplyFilters: (SearchFilterSelection) -> Void

    var body: some View {
        Group {
            Menu {
                ForEach(VideoSearchOrder.allCases) { order in
                    Toggle(
                        isOn: Binding(
                            get: { selection.order == order },
                            set: { isSelected in
                                guard isSelected else { return }
                                selection.order = order
                                onSelectOrder(order)
                            }
                        )
                    ) {
                        Text(order.localizedTitle(locale: locale))
                    }
                }
            } label: {
                Label {
                    Text(selection.order.localizedTitle(locale: locale))
                } icon: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .labelStyle(.titleAndIcon)
            }
            .help(
                AppStrings.localized(
                    "搜索结果排序：\(selection.order.localizedTitle(locale: locale))",
                    locale: locale
                )
            )

            Button {
                draft = selection
                isFilterPopoverPresented = true
            } label: {
                Label {
                    Text(filterButtonTitle)
                } icon: {
                    Image(systemName: filterButtonImage)
                }
                .labelStyle(.titleAndIcon)
            }
            .accessibilityValue(
                Text(
                    AppStrings.localized(
                        "已启用 \(selection.activeFilterCount) 项",
                        locale: locale
                    )
                )
            )
            .help(filterButtonHelp)
            .popover(isPresented: $isFilterPopoverPresented, arrowEdge: .bottom) {
                SearchFilterPopover(
                    draft: $draft,
                    onCancel: cancelDraft,
                    onApply: applyDraft
                )
            }
            .onChange(of: isFilterPopoverPresented) { _, isPresented in
                if !isPresented {
                    draft = selection
                }
            }
        }
    }

    private var filterButtonTitle: String {
        if selection.activeFilterCount == 0 {
            AppStrings.localized("筛选", locale: locale)
        } else {
            AppStrings.localized(
                "筛选 \(selection.activeFilterCount)",
                locale: locale
            )
        }
    }

    private var filterButtonImage: String {
        selection.activeFilterCount == 0
            ? "line.3.horizontal.decrease.circle"
            : "line.3.horizontal.decrease.circle.fill"
    }

    private var filterButtonHelp: String {
        let summary = selection.summary(locale: locale)
        return summary.isEmpty
            ? AppStrings.localized("筛选搜索结果", locale: locale)
            : AppStrings.localized("筛选搜索结果：\(summary)", locale: locale)
    }

    private func cancelDraft() {
        draft = selection
        isFilterPopoverPresented = false
    }

    private func applyDraft() {
        selection = draft
        isFilterPopoverPresented = false
        onApplyFilters(draft)
    }
}

private struct SearchFilterPopover: View {
    @Environment(\.locale) private var locale
    @Binding var draft: SearchFilterSelection
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppStrings.localized("筛选搜索结果", locale: locale))
                .font(.headline)

            LabeledContent(AppStrings.localized("发布日期", locale: locale)) {
                Picker(AppStrings.localized("发布日期", locale: locale), selection: $draft.publication)
                {
                    ForEach(VideoPublicationFilter.allCases) { filter in
                        Text(filter.localizedTitle(locale: locale)).tag(filter)
                    }
                }
                .labelsHidden()
                .frame(width: 176)
            }

            if draft.publication == .custom {
                VStack(alignment: .leading, spacing: 10) {
                    DatePicker(
                        AppStrings.localized("开始日期", locale: locale),
                        selection: $draft.customStart,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    DatePicker(
                        AppStrings.localized("结束日期", locale: locale),
                        selection: $draft.customEnd,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    if let validationMessage {
                        Label {
                            Text(validationMessage)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                }
                .padding(.leading, 12)
            }

            LabeledContent(AppStrings.localized("视频时长", locale: locale)) {
                Picker(AppStrings.localized("视频时长", locale: locale), selection: $draft.duration) {
                    ForEach(VideoDurationFilter.allCases) { duration in
                        Text(duration.localizedTitle(locale: locale)).tag(duration)
                    }
                }
                .labelsHidden()
                .frame(width: 176)
            }

            Divider()

            HStack {
                Button(AppStrings.localized("恢复默认", locale: locale)) {
                    draft.resetFilters()
                }
                .disabled(draft.activeFilterCount == 0)
                Spacer()
                Button(AppStrings.localized("取消", locale: locale), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(AppStrings.localized("应用", locale: locale), action: onApply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationMessage != nil)
            }
        }
        .padding(16)
        .frame(width: 350)
    }

    private var validationMessage: String? {
        guard draft.publication == .custom else { return nil }
        do {
            _ = try draft.resolvedFilters()
            return nil
        } catch let error as VideoPublicationRangeError {
            switch error {
            case .startAfterEnd:
                return AppStrings.localized("开始日期不能晚于结束日期", locale: locale)
            case .futureDate:
                return AppStrings.localized("结束日期不能超过今天", locale: locale)
            case .invalidCalendarRange:
                return AppStrings.localized("无法使用这个日期范围", locale: locale)
            }
        } catch {
            return AppStrings.localized("无法使用这个日期范围", locale: locale)
        }
    }
}

extension VideoSearchOrder {
    func localizedTitle(locale: Locale = .current) -> String {
        switch self {
        case .relevance: AppStrings.localized("综合排序", locale: locale)
        case .mostPlayed: AppStrings.localized("最多播放", locale: locale)
        case .newest: AppStrings.localized("最新发布", locale: locale)
        case .mostDanmaku: AppStrings.localized("最多弹幕", locale: locale)
        case .mostFavorited: AppStrings.localized("最多收藏", locale: locale)
        }
    }
}

extension VideoDurationFilter {
    func localizedTitle(locale: Locale = .current) -> String {
        switch self {
        case .all: AppStrings.localized("全部时长", locale: locale)
        case .underTenMinutes: AppStrings.localized("10 分钟以下", locale: locale)
        case .tenToThirtyMinutes: AppStrings.localized("10–30 分钟", locale: locale)
        case .thirtyToSixtyMinutes: AppStrings.localized("30–60 分钟", locale: locale)
        case .overSixtyMinutes: AppStrings.localized("60 分钟以上", locale: locale)
        }
    }
}

extension VideoPublicationFilter {
    func localizedTitle(locale: Locale = .current) -> String {
        switch self {
        case .all: AppStrings.localized("全部日期", locale: locale)
        case .today: AppStrings.localized("今天", locale: locale)
        case .lastSevenDays: AppStrings.localized("最近一周", locale: locale)
        case .last180Days: AppStrings.localized("最近半年", locale: locale)
        case .custom: AppStrings.localized("自定义日期", locale: locale)
        }
    }
}
