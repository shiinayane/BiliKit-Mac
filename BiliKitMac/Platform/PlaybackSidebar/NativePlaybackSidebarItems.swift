import AppKit
import BiliBrowseFeature
import BiliModels
import BiliUI

@MainActor
enum NativePlaybackSidebarItemMeasurement {
    static let avatarSize: CGFloat = 48
    static let rowHeight: CGFloat = 26
    static let textSpacing: CGFloat = 4
    static let sectionSpacing: CGFloat = 10
    static let dividerInset: CGFloat = 8
    static let sectionTopInset: CGFloat = 13

    static func uploader(
        _ content: VideoUploaderHeaderContent,
        width: CGFloat,
        signatureExpanded: Bool
    ) -> CGFloat {
        NativePlaybackUploaderGeometry(
            content: content,
            width: width,
            signatureExpanded: signatureExpanded
        ).height
    }

    static func summary(
        _ summary: String,
        width: CGFloat,
        expanded: Bool
    ) -> CGFloat {
        NativePlaybackSummaryGeometry(summary: summary, width: width, expanded: expanded).height
    }

    static func selection(
        _ projection: PlaybackSelectionProjection,
        width: CGFloat,
        browsedSectionID: VideoCollectionSectionIdentity?
    ) -> CGFloat {
        var heights: [CGFloat] = []
        if projection.collectionTitle != nil {
            heights.append(22)
        }
        if projection.showsSectionPicker {
            heights.append(rowHeight)
        }
        if projection.showsEpisodePicker {
            heights.append(rowHeight)
        }
        if let placeholder = projection.episodePlaceholder {
            heights.append(
                NativePlaybackSidebarTextLayout.height(
                    placeholder,
                    width: width,
                    font: .preferredFont(forTextStyle: .callout)
                )
            )
        }
        if browsedSectionID == projection.selectedEpisodeSectionID {
            switch projection.selectedPages {
            case .ready(let pages) where pages.count > 1:
                heights.append(rowHeight)
            case .loading, .failed:
                heights.append(rowHeight)
            case .ready, .empty:
                break
            }
        }
        guard !heights.isEmpty else { return 1 }
        return sectionTopInset + heights.reduce(0, +)
            + CGFloat(heights.count - 1) * sectionSpacing
    }
}

/// UP 主行的唯一几何来源；高度测量与 `layout()` 共用，缓存高度不会与实际布局漂移。
@MainActor
struct NativePlaybackUploaderGeometry {
    static let textLeading = NativePlaybackSidebarItemMeasurement.avatarSize + 12
    static let signatureToggleWidth: CGFloat = 48
    static let signatureToggleHeight: CGFloat = 20
    static let signatureToggleGap: CGFloat = 4
    static let loadingBarInset: CGFloat = 2
    static let loadingBarHeight: CGFloat = 14
    static let loadingBarMaximumWidth: CGFloat = 196
    static var nameFont: NSFont {
        .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize,
            weight: .semibold
        )
    }
    static var signatureFont: NSFont { .preferredFont(forTextStyle: .callout) }

    let nameFrame: NSRect
    let signatureTextFrame: NSRect
    let loadingBarFrame: NSRect
    let signatureToggleFrame: NSRect
    /// 签名超过一行时显示展开／收起按钮；收起时只显示一行。
    let signatureOverflows: Bool
    let signatureMaximumLines: Int?
    let height: CGFloat

    init(content: VideoUploaderHeaderContent, width: CGFloat, signatureExpanded: Bool) {
        let textWidth = max(40, width - Self.textLeading)
        let nameHeight = ceil(Self.nameFont.pointSize * 1.35)
        let signatureY = nameHeight + NativePlaybackSidebarItemMeasurement.textSpacing
        var overflows = false
        var maximumLines: Int?
        let signatureHeight: CGFloat
        switch content.signature {
        case .hidden:
            signatureHeight = 0
        case .loading:
            signatureHeight = Self.loadingBarInset + Self.loadingBarHeight
        case .text(let signature):
            overflows =
                NativePlaybackSidebarTextLayout.singleLineWidth(signature, font: Self.signatureFont)
                > textWidth
            maximumLines = overflows && !signatureExpanded ? 1 : nil
            signatureHeight = NativePlaybackSidebarTextLayout.height(
                signature,
                width: Self.signatureTextWidth(textWidth: textWidth, overflows: overflows),
                font: Self.signatureFont,
                maximumLines: maximumLines
            )
        }
        signatureOverflows = overflows
        signatureMaximumLines = maximumLines
        nameFrame = NSRect(x: Self.textLeading, y: 0, width: textWidth, height: nameHeight)
        signatureTextFrame = NSRect(
            x: Self.textLeading,
            y: signatureY,
            width: Self.signatureTextWidth(textWidth: textWidth, overflows: overflows),
            height: signatureHeight
        )
        loadingBarFrame = NSRect(
            x: Self.textLeading,
            y: signatureY + Self.loadingBarInset,
            width: min(Self.loadingBarMaximumWidth, textWidth),
            height: Self.loadingBarHeight
        )
        let toggleWidth = overflows ? Self.signatureToggleWidth : 0
        signatureToggleFrame = NSRect(
            x: width - toggleWidth,
            y: signatureY,
            width: toggleWidth,
            height: Self.signatureToggleHeight
        )
        let textHeight =
            nameHeight
            + (signatureHeight > 0
                ? NativePlaybackSidebarItemMeasurement.textSpacing + signatureHeight : 0)
        height = max(NativePlaybackSidebarItemMeasurement.avatarSize, textHeight)
    }

    private static func signatureTextWidth(textWidth: CGFloat, overflows: Bool) -> CGFloat {
        overflows
            ? max(1, textWidth - signatureToggleWidth - signatureToggleGap)
            : textWidth
    }
}

/// 简介区的唯一几何来源；正文最多测量两次（完整与五行），测量与布局共用结果。
@MainActor
struct NativePlaybackSummaryGeometry {
    static let collapsedLineLimit = 5
    static let titleHeight: CGFloat = 22
    static let titleToTextSpacing: CGFloat = 8
    static let toggleSpacing: CGFloat = 4
    static let toggleHeight: CGFloat = 22
    static let toggleMaximumWidth: CGFloat = 56
    static var textFont: NSFont { .preferredFont(forTextStyle: .callout) }

    let titleFrame: NSRect
    let textFrame: NSRect
    let toggleFrame: NSRect
    let overflows: Bool
    let maximumLines: Int?
    let height: CGFloat

    init(summary: String, width: CGFloat, expanded: Bool) {
        let topInset = NativePlaybackSidebarItemMeasurement.sectionTopInset
        let collapsedHeight = NativePlaybackSidebarTextLayout.height(
            summary,
            width: width,
            font: Self.textFont,
            maximumLines: Self.collapsedLineLimit
        )
        let fullHeight = NativePlaybackSidebarTextLayout.height(
            summary,
            width: width,
            font: Self.textFont
        )
        overflows = fullHeight > collapsedHeight + 0.5
        maximumLines = overflows && !expanded ? Self.collapsedLineLimit : nil
        titleFrame = NSRect(x: 0, y: topInset, width: width, height: Self.titleHeight)
        textFrame = NSRect(
            x: 0,
            y: titleFrame.maxY + Self.titleToTextSpacing,
            width: width,
            height: expanded && overflows ? fullHeight : collapsedHeight
        )
        toggleFrame = NSRect(
            x: 0,
            y: textFrame.maxY + Self.toggleSpacing,
            width: min(Self.toggleMaximumWidth, width),
            height: overflows ? Self.toggleHeight : 0
        )
        height = overflows ? toggleFrame.maxY : textFrame.maxY
    }
}

@MainActor
final class NativePlaybackSidebarReadOnlyTextView: NSTextView {
    init(font: NSFont, color: NSColor = .labelColor) {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        super.init(frame: .zero, textContainer: container)
        drawsBackground = false
        isEditable = false
        isSelectable = true
        isRichText = true
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainerInset = .zero
        typingAttributes = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: NativePlaybackSidebarTextLayout.paragraphStyle
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        textContainer?.containerSize = NSSize(
            width: max(1, bounds.width),
            height: CGFloat.greatestFiniteMagnitude
        )
        super.layout()
    }

    func setText(
        _ text: String,
        font: NSFont,
        color: NSColor,
        maximumLines: Int? = nil
    ) {
        let previousSelections = selectedRanges
        textContainer?.maximumNumberOfLines = maximumLines ?? 0
        textContainer?.lineBreakMode = maximumLines == nil ? .byCharWrapping : .byTruncatingTail
        textStorage?.setAttributedString(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: NativePlaybackSidebarTextLayout.paragraphStyle(
                        maximumLines: maximumLines
                    )
                ]
            )
        )
        let textLength = (text as NSString).length
        selectedRanges = Self.clampedSelections(
            previousSelections,
            textLength: textLength
        )
    }

    static func clampedSelections(
        _ selections: [NSValue],
        textLength: Int
    ) -> [NSValue] {
        selections.map { value in
            let range = value.rangeValue
            let location = min(range.location, textLength)
            return NSValue(
                range: NSRange(
                    location: location,
                    length: min(range.length, textLength - location)
                )
            )
        }
    }
}

@MainActor
final class NativePlaybackSidebarUnavailableItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier(
        "NativePlaybackSidebarUnavailableItem"
    )

    private let titleLabel = NSTextField(labelWithString: AppStrings.localized("评论尚未接入"))
    private let messageLabel = NSTextField(
        wrappingLabelWithString: AppStrings.localized("当前版本不会伪造评论内容。")
    )
    private let separator = NSBox()

    override func loadView() {
        let root = NativePlaybackSidebarFlippedView()
        titleLabel.font = .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .headline).pointSize,
            weight: .semibold
        )
        messageLabel.font = .preferredFont(forTextStyle: .callout)
        messageLabel.textColor = .secondaryLabelColor
        separator.boxType = .separator
        for subview in [separator, titleLabel, messageLabel] {
            root.addSubview(subview)
        }
        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        separator.frame = NSRect(
            x: 0,
            y: 0,
            width: view.bounds.width,
            height: 1
        )
        titleLabel.frame = NSRect(x: 0, y: 13, width: view.bounds.width, height: 20)
        messageLabel.frame = NSRect(x: 0, y: 35, width: view.bounds.width, height: 18)
    }
}

@MainActor
final class NativePlaybackSidebarFlippedView: NSView {
    override var isFlipped: Bool { true }
}
