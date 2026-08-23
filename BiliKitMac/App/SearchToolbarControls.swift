import BiliBrowseFeature
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

    var summary: String {
        [
            publication == .all ? nil : publication.localizedTitle,
            duration == .all ? nil : duration.localizedTitle,
        ].compactMap { $0 }.joined(separator: "，")
    }
}

struct SearchToolbarControls: View {
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
                        Text(order.title)
                    }
                }
            } label: {
                Label {
                    Text(selection.order.title)
                } icon: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .labelStyle(.titleAndIcon)
            }
            .help(
                String(
                    localized: "搜索结果排序：\(selection.order.localizedTitle)"
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
                Text("已启用 \(selection.activeFilterCount) 项")
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

    private var filterButtonTitle: LocalizedStringResource {
        if selection.activeFilterCount == 0 {
            "筛选"
        } else {
            "筛选 \(selection.activeFilterCount)"
        }
    }

    private var filterButtonImage: String {
        selection.activeFilterCount == 0
            ? "line.3.horizontal.decrease.circle"
            : "line.3.horizontal.decrease.circle.fill"
    }

    private var filterButtonHelp: String {
        selection.summary.isEmpty
            ? String(localized: "筛选搜索结果")
            : String(localized: "筛选搜索结果：\(selection.summary)")
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
    @Binding var draft: SearchFilterSelection
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("筛选搜索结果")
                .font(.headline)

            LabeledContent("发布日期") {
                Picker("发布日期", selection: $draft.publication) {
                    ForEach(VideoPublicationFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .labelsHidden()
                .frame(width: 176)
            }

            if draft.publication == .custom {
                VStack(alignment: .leading, spacing: 10) {
                    DatePicker(
                        "开始日期",
                        selection: $draft.customStart,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    DatePicker(
                        "结束日期",
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

            LabeledContent("视频时长") {
                Picker("视频时长", selection: $draft.duration) {
                    ForEach(VideoDurationFilter.allCases) { duration in
                        Text(duration.title).tag(duration)
                    }
                }
                .labelsHidden()
                .frame(width: 176)
            }

            Divider()

            HStack {
                Button("恢复默认") {
                    draft.resetFilters()
                }
                .disabled(draft.activeFilterCount == 0)
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("应用", action: onApply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationMessage != nil)
            }
        }
        .padding(16)
        .frame(width: 350)
    }

    private var validationMessage: LocalizedStringResource? {
        guard draft.publication == .custom else { return nil }
        do {
            _ = try draft.resolvedFilters()
            return nil
        } catch let error as VideoPublicationRangeError {
            switch error {
            case .startAfterEnd:
                return "开始日期不能晚于结束日期"
            case .futureDate:
                return "结束日期不能超过今天"
            case .invalidCalendarRange:
                return "无法使用这个日期范围"
            }
        } catch {
            return "无法使用这个日期范围"
        }
    }
}

extension VideoSearchOrder {
    var title: LocalizedStringResource {
        switch self {
        case .relevance: "综合排序"
        case .mostPlayed: "最多播放"
        case .newest: "最新发布"
        case .mostDanmaku: "最多弹幕"
        case .mostFavorited: "最多收藏"
        }
    }

    var localizedTitle: String { String(localized: title) }
}

extension VideoDurationFilter {
    var title: LocalizedStringResource {
        switch self {
        case .all: "全部时长"
        case .underTenMinutes: "10 分钟以下"
        case .tenToThirtyMinutes: "10–30 分钟"
        case .thirtyToSixtyMinutes: "30–60 分钟"
        case .overSixtyMinutes: "60 分钟以上"
        }
    }

    var localizedTitle: String { String(localized: title) }
}

extension VideoPublicationFilter {
    var title: LocalizedStringResource {
        switch self {
        case .all: "全部日期"
        case .today: "最近一天"
        case .lastSevenDays: "最近一周"
        case .last180Days: "最近半年"
        case .custom: "自定义日期"
        }
    }

    var localizedTitle: String { String(localized: title) }
}
