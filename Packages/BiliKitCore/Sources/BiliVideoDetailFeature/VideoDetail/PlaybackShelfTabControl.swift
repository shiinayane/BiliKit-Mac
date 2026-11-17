import AppKit
import SwiftUI

/// 横排标题行的分页切换。
///
/// 用 `NSSegmentedControl` 而不用 SwiftUI 分段 `Picker`：再点一次已选中的分页要回到当前一集或开头，
/// `Picker` 在选中值不变时不回调，`NSSegmentedControl` 每次点击都发动作。
struct PlaybackShelfTabControl: NSViewRepresentable {
    let tabs: [PlaybackShelfTab]
    let selection: PlaybackShelfTab
    let onSelect: (PlaybackShelfTab) -> Void
    let onReselect: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.target = context.coordinator
        control.action = #selector(Coordinator.segmentClicked(_:))
        control.setAccessibilityLabel(VideoDetailFeatureStrings.localized("横排内容"))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        let coordinator = context.coordinator
        coordinator.tabs = tabs
        coordinator.selection = selection
        coordinator.onSelect = onSelect
        coordinator.onReselect = onReselect
        if control.segmentCount != tabs.count {
            control.segmentCount = tabs.count
        }
        for (index, tab) in tabs.enumerated() where control.label(forSegment: index) != tab.title {
            control.setLabel(tab.title, forSegment: index)
            control.setWidth(0, forSegment: index)
        }
        if let index = tabs.firstIndex(of: selection), control.selectedSegment != index {
            control.selectedSegment = index
        }
        control.invalidateIntrinsicContentSize()
    }

    /// 分段控件的动作目标：持有最近一次的分页列表、选中项与回调；点到已选中的分页走 `onReselect`。
    @MainActor
    final class Coordinator: NSObject {
        var tabs: [PlaybackShelfTab] = []
        var selection: PlaybackShelfTab?
        var onSelect: (PlaybackShelfTab) -> Void = { _ in }
        var onReselect: () -> Void = {}

        @objc func segmentClicked(_ control: NSSegmentedControl) {
            let index = control.selectedSegment
            guard tabs.indices.contains(index) else { return }
            let tab = tabs[index]
            if tab == selection {
                onReselect()
            } else {
                selection = tab
                onSelect(tab)
            }
        }
    }
}

extension PlaybackShelfTab {
    var title: String {
        switch self {
        case .related: VideoDetailFeatureStrings.localized("相关视频")
        case .recent: VideoDetailFeatureStrings.localized("刚才看过")
        case .chapters: VideoDetailFeatureStrings.localized("章节")
        case .collection: VideoDetailFeatureStrings.localized("合集")
        }
    }
}
