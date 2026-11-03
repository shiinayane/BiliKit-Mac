import AppKit
import BiliModels
import BiliUI

/// 侧栏非评论条目的尺寸常量与高度测量；测量与各条目的 `layout()` 共用同一组几何，缓存的行高不会与实际布局漂移。
@MainActor
enum NativePlaybackSidebarItemMeasurement {
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
///
/// 行高按名字、计数、签名三行都在时计算，与名片状态无关：加载中两行占位，到达后缺了哪行也不改行高，名片到达的过渡只需
/// 覆盖这一行（见 `NativePlaybackUploaderProfileReveal`）。实际出现的几行作为一块、与头像一起在行内上下居中；“查看空间”
/// 箭头紧跟在名字末尾，像一个可点的标题；关注按钮独占行尾、与头像一起上下居中，文字各行都止于它左侧。
@MainActor
struct NativePlaybackUploaderGeometry {
    static let textLeading = NativePlaybackSidebarItemMeasurement.avatarSize + 12
    /// 名字末尾“查看空间”箭头按钮的边长，以及它与名字之间的间距。
    static let spaceButtonSize: CGFloat = 16
    static let spaceButtonSpacing: CGFloat = 2
    /// 关注按钮与左侧文字之间的间距。
    static let followButtonSpacing: CGFloat = 12
    static let loadingBarHeight: CGFloat = 12
    static let statsLoadingBarWidth: CGFloat = 120
    static let signatureLoadingBarWidth: CGFloat = 196
    static var nameFont: NSFont {
        .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize,
            weight: .semibold
        )
    }
    static var statsFont: NSFont {
        .monospacedDigitSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .regular
        )
    }
    static var signatureFont: NSFont { .preferredFont(forTextStyle: .callout) }
    static var followTitle: String { VideoDetailFeatureStrings.localized("关注") }
    static var followingTitle: String { VideoDetailFeatureStrings.localized("已关注") }

    let avatarFrame: NSRect
    /// 名字行可用的整段宽度；名字与箭头的实际位置由 `nameRow` 在其中排出。
    let nameFrame: NSRect
    /// 计数与签名各一行，固定单行、超出省略；隐藏时高度为 0。
    let statsFrame: NSRect
    let signatureTextFrame: NSRect
    /// 加载中占位条；不在加载时为 `.zero`。
    let statsLoadingBarFrame: NSRect
    let signatureLoadingBarFrame: NSRect
    /// 没有关注按钮时为 `.zero`。
    let followButtonFrame: NSRect
    let height: CGFloat

    init(content: VideoUploaderHeaderContent, width: CGFloat) {
        let spacing = NativePlaybackSidebarItemMeasurement.textSpacing
        let avatarSize = NativePlaybackSidebarItemMeasurement.avatarSize
        let nameHeight = ceil(Self.nameFont.pointSize * 1.35)
        let statsHeight = Self.statsLineHeight
        let signatureHeight = Self.signatureLineHeight
        height = max(
            avatarSize,
            nameHeight + spacing + statsHeight + spacing + signatureHeight
        )
        avatarFrame = NSRect(
            x: 0,
            y: floor((height - avatarSize) / 2),
            width: avatarSize,
            height: avatarSize
        )

        let followSize = content.follow == nil ? NSSize.zero : Self.followButtonSize
        followButtonFrame =
            content.follow == nil
            ? .zero
            : NSRect(
                x: width - followSize.width,
                y: floor((height - followSize.height) / 2),
                width: followSize.width,
                height: followSize.height
            )
        let trailingReserve =
            content.follow == nil ? 0 : followSize.width + Self.followButtonSpacing
        let textWidth = max(40, width - Self.textLeading - trailingReserve)

        let lineHeights =
            [nameHeight]
            + (content.stats == .hidden ? [] : [statsHeight])
            + (content.signature == .hidden ? [] : [signatureHeight])
        let blockHeight =
            lineHeights.reduce(0, +) + spacing * CGFloat(lineHeights.count - 1)
        var y = floor((height - blockHeight) / 2)
        func nextLine(_ lineHeight: CGFloat, isPresent: Bool) -> NSRect {
            let frame = NSRect(
                x: Self.textLeading,
                y: y,
                width: textWidth,
                height: isPresent ? lineHeight : 0
            )
            if isPresent { y += lineHeight + spacing }
            return frame
        }
        nameFrame = nextLine(nameHeight, isPresent: true)
        statsFrame = nextLine(statsHeight, isPresent: content.stats != .hidden)
        signatureTextFrame = nextLine(signatureHeight, isPresent: content.signature != .hidden)
        statsLoadingBarFrame =
            content.stats == .loading
            ? Self.loadingBar(in: statsFrame, maximumWidth: Self.statsLoadingBarWidth) : .zero
        signatureLoadingBarFrame =
            content.signature == .loading
            ? Self.loadingBar(in: signatureTextFrame, maximumWidth: Self.signatureLoadingBarWidth)
            : .zero
    }

    /// 名字与紧随其后的箭头：名字按不截断时的宽度 `nameWidth` 排，放不下时截断、给箭头留出位置；没有空间入口时箭头为
    /// `.zero`，名字可占满整段。
    func nameRow(
        nameWidth: CGFloat,
        showsSpaceButton: Bool
    ) -> (name: NSRect, spaceButton: NSRect) {
        let buttonSize = Self.spaceButtonSize
        let reserve = showsSpaceButton ? buttonSize + Self.spaceButtonSpacing : 0
        var name = nameFrame
        name.size.width = max(0, min(ceil(nameWidth), nameFrame.width - reserve))
        guard showsSpaceButton else { return (name, .zero) }
        let button = NSRect(
            x: name.maxX + Self.spaceButtonSpacing,
            y: floor(nameFrame.midY - buttonSize / 2),
            width: buttonSize,
            height: buttonSize
        )
        return (name, button)
    }

    private static func loadingBar(in line: NSRect, maximumWidth: CGFloat) -> NSRect {
        NSRect(
            x: line.minX,
            y: floor(line.midY - loadingBarHeight / 2),
            width: min(maximumWidth, line.width),
            height: loadingBarHeight
        )
    }

    /// 计数与签名的单行标签：超出省略，被截断时由系统原地浮出完整文字（expansion tooltip）。
    ///
    /// 真实标签与测量用标签都由这里创建，保证行高测量与实际绘制一致。
    static func makeStatsLabel() -> NSTextField {
        makeSingleLineLabel(font: statsFont)
    }

    static func makeSignatureLabel() -> NSTextField {
        makeSingleLineLabel(font: signatureFont)
    }

    private static func makeSingleLineLabel(font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.isSelectable = false
        label.allowsExpansionToolTips = true
        return label
    }

    /// 关注按钮；真实按钮与测量用按钮都由这里创建，宽度按两种标题中较宽的一个算，切换关注状态时名字的宽度不跳动。
    static func makeFollowButton() -> NSButton {
        let button = NSButton(title: followTitle, target: nil, action: nil)
        button.bezelStyle = .push
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        return button
    }

    /// 名字标签；真实标签与测量用标签都由这里创建，名字的不截断宽度按同一字体与内边距测量。
    static func makeNameLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = nameFont
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        // 名字这一行可点，名字不再可选中复制，否则文本框会吃掉点击。
        label.isSelectable = false
        return label
    }

    /// 名字不截断时的宽度，交给 `nameRow`。
    static func nameWidth(_ name: String) -> CGFloat {
        nameSizingLabel.font = nameFont
        nameSizingLabel.stringValue = name
        return ceil(nameSizingLabel.fittingSize.width)
    }

    private static let nameSizingLabel = makeNameLabel()
    private static let statsSizingLabel = makeStatsLabel()
    private static let signatureSizingLabel = makeSignatureLabel()
    private static let followSizingButton = makeFollowButton()

    /// 单行计数与签名标签的高度；测量与布局共用，测量标签复用同一个实例。
    static var statsLineHeight: CGFloat {
        lineHeight(of: statsSizingLabel, font: statsFont)
    }

    static var signatureLineHeight: CGFloat {
        lineHeight(of: signatureSizingLabel, font: signatureFont)
    }

    private static func lineHeight(of label: NSTextField, font: NSFont) -> CGFloat {
        label.font = font
        label.stringValue = "Ag签"
        return ceil(label.fittingSize.height)
    }

    static var followButtonSize: NSSize {
        var size = NSSize.zero
        for title in [followTitle, followingTitle] {
            followSizingButton.title = title
            let fitting = followSizingButton.fittingSize
            size.width = max(size.width, ceil(fitting.width))
            size.height = max(size.height, ceil(fitting.height))
        }
        return size
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

/// 只读侧栏文字与其中的链接；时间戳是否可点取决于 `timestampLimitSeconds`。
struct NativePlaybackSidebarLinkedText: Equatable {
    let text: String
    let links: [CommentLink]
    let timestampLimitSeconds: Int?
}

/// 侧栏里只读、可选中的文字；链接点击经 `onOpenLink` 交出，与评论正文同一套链接值。
@MainActor
final class NativePlaybackSidebarReadOnlyTextView: NSTextView, NSTextViewDelegate {
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

    /// 链接只改颜色、不改字形，行高测量用纯文字即可。
    func setText(
        _ text: NativePlaybackSidebarLinkedText,
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
                .paragraphStyle: NativePlaybackSidebarTextLayout.paragraphStyle(
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
