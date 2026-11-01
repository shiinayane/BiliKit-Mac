import AppKit
import BiliModels
import BiliUI

/// 详情区非评论条目的尺寸常量与高度测量；测量与各条目的 `layout()` 共用同一组几何，缓存的行高不会与实际布局漂移。
@MainActor
enum NativePlaybackDetailsItemMeasurement {
    static let avatarSize: CGFloat = 48
    static let rowHeight: CGFloat = 26
    static let textSpacing: CGFloat = 4
    static let sectionSpacing: CGFloat = 10
    static let dividerInset: CGFloat = 8
    static let sectionTopInset: CGFloat = 13

    static func uploader(_ content: VideoUploaderHeaderContent, width: CGFloat) -> CGFloat {
        NativePlaybackUploaderGeometry(content: content, width: width).height
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
                NativePlaybackDetailsTextLayout.height(
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
    static let textLeading = NativePlaybackDetailsItemMeasurement.avatarSize + 12
    /// 名字行右侧“查看空间”箭头按钮的边长，以及它与名字之间的间距。
    static let spaceButtonSize: CGFloat = 16
    static let spaceButtonSpacing: CGFloat = 8
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
    /// 签名固定一行，超出部分省略，完整文字由系统 expansion tooltip 显示。
    let signatureTextFrame: NSRect
    let loadingBarFrame: NSRect
    let height: CGFloat

    init(content: VideoUploaderHeaderContent, width: CGFloat) {
        let textWidth = max(40, width - Self.textLeading)
        let nameHeight = ceil(Self.nameFont.pointSize * 1.35)
        let signatureY = nameHeight + NativePlaybackDetailsItemMeasurement.textSpacing
        // 没有签名时名字与头像上下居中，否则名字贴顶、签名在下。
        let nameY =
            content.signature == .hidden
            ? max(0, (NativePlaybackDetailsItemMeasurement.avatarSize - nameHeight) / 2)
            : 0
        let signatureHeight: CGFloat
        switch content.signature {
        case .hidden:
            signatureHeight = 0
        case .loading:
            signatureHeight = Self.loadingBarInset + Self.loadingBarHeight
        case .text:
            signatureHeight = Self.signatureLineHeight
        }
        nameFrame = NSRect(x: Self.textLeading, y: nameY, width: textWidth, height: nameHeight)
        signatureTextFrame = NSRect(
            x: Self.textLeading,
            y: signatureY,
            width: textWidth,
            height: signatureHeight
        )
        loadingBarFrame = NSRect(
            x: Self.textLeading,
            y: signatureY + Self.loadingBarInset,
            width: min(Self.loadingBarMaximumWidth, textWidth),
            height: Self.loadingBarHeight
        )
        let textHeight =
            nameHeight
            + (signatureHeight > 0
                ? NativePlaybackDetailsItemMeasurement.textSpacing + signatureHeight : 0)
        height = max(NativePlaybackDetailsItemMeasurement.avatarSize, textHeight)
    }

    /// 签名标签：一行，超出省略，被截断时由系统原地浮出完整文字（expansion tooltip）。
    ///
    /// 真实标签与测量用标签都由这里创建，保证行高测量与实际绘制一致。
    static func makeSignatureLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = signatureFont
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.isSelectable = false
        label.allowsExpansionToolTips = true
        return label
    }

    private static let signatureSizingLabel = makeSignatureLabel()

    /// 单行签名标签的高度；测量与布局共用，测量标签复用同一个实例。
    static var signatureLineHeight: CGFloat {
        signatureSizingLabel.font = signatureFont
        signatureSizingLabel.stringValue = "Ag签"
        return ceil(signatureSizingLabel.fittingSize.height)
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
        let topInset = NativePlaybackDetailsItemMeasurement.sectionTopInset
        let collapsedHeight = NativePlaybackDetailsTextLayout.height(
            summary,
            width: width,
            font: Self.textFont,
            maximumLines: Self.collapsedLineLimit
        )
        let fullHeight = NativePlaybackDetailsTextLayout.height(
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

/// 只读详情区文字与其中的链接；时间戳是否可点取决于 `timestampLimitSeconds`。
struct NativePlaybackDetailsLinkedText: Equatable {
    let text: String
    let links: [CommentLink]
    let timestampLimitSeconds: Int?
}

/// 详情区里只读、可选中的文字；链接点击经 `onOpenLink` 交出，与评论正文同一套链接值。
@MainActor
final class NativePlaybackDetailsReadOnlyTextView: NSTextView, NSTextViewDelegate {
    var onOpenLink: ((CommentLinkTarget) -> Void)?
    private var linkTargets: [CommentLinkTarget] = []

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
        delegate = self
        NativePlaybackTextLinks.configure(self)
        typingAttributes = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: NativePlaybackDetailsTextLayout.paragraphStyle
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

    /// 链接只改颜色、不改字形，行高测量用纯文字即可。
    func setText(
        _ text: NativePlaybackDetailsLinkedText,
        font: NSFont,
        color: NSColor,
        maximumLines: Int? = nil
    ) {
        let previousSelections = selectedRanges
        textContainer?.maximumNumberOfLines = maximumLines ?? 0
        textContainer?.lineBreakMode = maximumLines == nil ? .byCharWrapping : .byTruncatingTail
        let attributed = NSMutableAttributedString(
            string: text.text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: NativePlaybackDetailsTextLayout.paragraphStyle(
                    maximumLines: maximumLines
                )
            ]
        )
        let applied = NativePlaybackTextLinks.apply(
            text.links,
            to: attributed,
            timestampLimitSeconds: text.timestampLimitSeconds
        )
        linkTargets = applied.targets
        textStorage?.setAttributedString(attributed)
        selectedRanges = Self.clampedSelections(
            previousSelections,
            textLength: attributed.length
        )
    }

    func textView(
        _ textView: NSTextView,
        clickedOnLink link: Any,
        at charIndex: Int
    ) -> Bool {
        if let target = NativePlaybackTextLinks.target(for: link, in: linkTargets) {
            onOpenLink?(target)
        }
        return true
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
