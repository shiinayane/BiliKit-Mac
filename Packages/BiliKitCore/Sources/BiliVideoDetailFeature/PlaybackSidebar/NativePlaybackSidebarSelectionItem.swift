import AppKit
import BiliModels
import BiliUI
import BiliVideoCollectionUI

/// 侧栏的分 P 条目：所选视频的分 P 菜单，或所选选集的分 P 读取中／读取失败与重试。
///
/// 只呈现 `PlaybackSelectionProjection`；合集、分区与选集在播放页的合集横排里。选择意图经回调交给控制器，
/// 再到 `VideoViewModel`。
@MainActor
final class NativePlaybackSidebarSelectionItem: NativeLayoutSizedCollectionItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier(
        "NativePlaybackSidebarSelectionItem"
    )

    private let contentView = NativePlaybackSidebarSelectionView()

    override func loadView() {
        view = contentView
    }

    func configure(
        projection: PlaybackSelectionProjection,
        onSelectPage: @escaping (Int64) -> Void,
        onRetryPages: @escaping () -> Void
    ) {
        representedObject = projection
        contentView.configure(
            projection: projection,
            onSelectPage: onSelectPage,
            onRetryPages: onRetryPages
        )
    }

    override func prepareForReuse() {
        contentView.reset()
        representedObject = nil
        super.prepareForReuse()
    }
}

/// 分 P 条目的内容视图：持有当前投影与回调，一行「分 P」标签加菜单或状态；行高与
/// `NativePlaybackSidebarItemMeasurement.selection` 一致。
@MainActor
private final class NativePlaybackSidebarSelectionView: NSView {
    override var isFlipped: Bool { true }

    private static let labelWidth: CGFloat = 46
    private static let labelControlSpacing: CGFloat = 8
    private static let retryButtonWidth: CGFloat = 54

    private let separator = NSBox()
    private let pageLabel = NSTextField(labelWithString: VideoDetailFeatureStrings.localized("分 P"))
    private let pagePopUp = NSPopUpButton()
    private let pageStatusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator.sidebarLoadingSpinner(controlSize: .small)
    /// 分 P 加载中的转圈与说明一起延迟露出；露出前这一行只有「分 P」标签。
    private lazy var pageLoadingReveal = NativeLoadingReveal { [weak self] revealed in
        guard let self else { return }
        progress.setSpinning(revealed)
        if revealed { pageStatusLabel.isHidden = false }
        needsLayout = true
    }
    private let retryButton = NSButton(
        title: VideoDetailFeatureStrings.localized("重试"),
        target: nil,
        action: nil
    )
    private var onSelectPage: ((Int64) -> Void)?
    private var onRetryPages: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pageStatusLabel.font = .preferredFont(forTextStyle: .callout)
        pageStatusLabel.textColor = .secondaryLabelColor
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.target = self
        retryButton.action = #selector(retryPages)
        pagePopUp.target = self
        separator.boxType = .separator
        for subview in [separator, pageLabel, pagePopUp, pageStatusLabel, progress, retryButton] {
            addSubview(subview)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        projection: PlaybackSelectionProjection,
        onSelectPage: @escaping (Int64) -> Void,
        onRetryPages: @escaping () -> Void
    ) {
        self.onSelectPage = onSelectPage
        self.onRetryPages = onRetryPages
        configurePages(projection)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        separator.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        let y = NativePlaybackSidebarItemMeasurement.sectionTopInset
        let rowHeight = NativePlaybackSidebarItemMeasurement.rowHeight
        pageLabel.frame = NSRect(x: 0, y: y + 3, width: Self.labelWidth, height: 20)
        let controlX = Self.labelWidth + Self.labelControlSpacing
        let controlWidth = max(1, width - controlX)
        pagePopUp.frame = NSRect(x: controlX, y: y, width: controlWidth, height: rowHeight)
        progress.frame = NSRect(x: controlX, y: y + 4, width: 16, height: 16)
        let retryReserve =
            retryButton.isHidden ? 0 : Self.retryButtonWidth + Self.labelControlSpacing / 2
        pageStatusLabel.frame = NSRect(
            x: controlX + (progress.isHidden ? 0 : 22),
            y: y + 3,
            width: max(1, controlWidth - retryReserve),
            height: 20
        )
        retryButton.frame = NSRect(
            x: max(controlX, width - Self.retryButtonWidth),
            y: y,
            width: Self.retryButtonWidth,
            height: rowHeight
        )
    }

    func reset() {
        onSelectPage = nil
        onRetryPages = nil
        pagePopUp.menu = nil
        pageStatusLabel.stringValue = ""
        pageLoadingReveal.setLoading(false)
    }

    private func configurePages(_ projection: PlaybackSelectionProjection) {
        pagePopUp.menu = nil
        pagePopUp.isHidden = true
        pageStatusLabel.isHidden = true
        retryButton.isHidden = true
        var isLoadingPages = false
        defer { pageLoadingReveal.setLoading(isLoadingPages) }

        switch projection.selectedPages {
        case .ready(let pages) where pages.count > 1:
            pagePopUp.isHidden = false
            let menu = NSMenu(title: VideoDetailFeatureStrings.localized("分 P"))
            var selectedItem: NSMenuItem?
            for page in pages {
                let item = NSMenuItem(
                    title: NativePlaybackSidebarSelectionItem.pageMenuTitle(
                        index: page.index,
                        title: page.title,
                        durationSeconds: page.durationSeconds
                    ),
                    action: #selector(selectPage(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = NSNumber(value: page.cid)
                if page.cid == projection.selectedPageCID {
                    selectedItem = item
                    item.state = .on
                }
                menu.addItem(item)
            }
            if selectedItem == nil {
                let fallback = NSMenuItem(
                    title: VideoDetailFeatureStrings.localized("请选择分 P"),
                    action: nil,
                    keyEquivalent: ""
                )
                fallback.isEnabled = false
                menu.insertItem(fallback, at: 0)
                selectedItem = fallback
            }
            pagePopUp.menu = menu
            if let selectedItem {
                pagePopUp.select(selectedItem)
            }
            pagePopUp.setAccessibilityLabel(VideoDetailFeatureStrings.localized("分 P"))
        case .loading:
            isLoadingPages = true
            pageStatusLabel.stringValue = VideoDetailFeatureStrings.localized("正在加载所选视频的分 P")
        case .failed:
            pageStatusLabel.isHidden = false
            retryButton.isHidden = false
            pageStatusLabel.stringValue = VideoDetailFeatureStrings.localized("无法加载所选视频的分 P")
        case .ready, .empty:
            break
        }
    }

    @objc private func selectPage(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSNumber else { return }
        onSelectPage?(value.int64Value)
    }

    @objc private func retryPages() {
        onRetryPages?()
    }
}

extension NativePlaybackSidebarSelectionItem {
    /// 分 P 菜单项：「P1 · 标题 · 时长」，标题为空时省略这一段（`VideoPage.displayLabel`）。
    static func pageMenuTitle(index: Int, title: String, durationSeconds: Int) -> String {
        VideoPage.displayLabel(index: index, title: title) + " · "
            + VideoDurationFormatting.string(seconds: durationSeconds)
    }
}
