import AppKit
import BiliModels
import CoreText

@MainActor
final class NativePlaybackCommentAuthorBadgesView: NSView {
    override var isFlipped: Bool { true }

    struct Segment {
        let text: String
        let foreground: NSColor
        let background: NSColor?
        let stroke: NSColor?
        let horizontalPadding: CGFloat
    }

    @MainActor
    private struct RenderedSegment {
        let text: String
        let background: NSColor?
        let stroke: NSColor?
        let textLine: CTLine
        let textSize: NSSize
        let baselineFromTop: CGFloat
        let width: CGFloat

        init(_ segment: Segment, font: NSFont) {
            text = segment.text
            background = segment.background
            stroke = segment.stroke
            let attributedText = NSAttributedString(
                string: segment.text,
                attributes: [
                    .font: font,
                    .foregroundColor: segment.foreground
                ]
            )
            textLine = CTLineCreateWithAttributedString(attributedText)
            textSize = attributedText.size()
            var ascent: CGFloat = 0
            CTLineGetTypographicBounds(textLine, &ascent, nil, nil)
            baselineFromTop = ascent
            width = ceil(textSize.width + segment.horizontalPadding * 2)
        }
    }

    private var segments: [RenderedSegment] = []
    private var cachedPreferredWidth: CGFloat = 0

    var preferredWidth: CGFloat { cachedPreferredWidth }

    static func preferredWidth(for author: CommentAuthor, isReply: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: isReply ? 9 : 10, weight: .bold)
        return preferredWidth(segments: segments(for: author), font: font)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(author: CommentAuthor, isReply: Bool) {
        let font = NSFont.systemFont(ofSize: isReply ? 9 : 10, weight: .bold)
        segments = Self.segments(for: author).map {
            RenderedSegment($0, font: font)
        }
        cachedPreferredWidth = Self.preferredWidth(segments: segments)
        isHidden = segments.isEmpty
        needsDisplay = true
    }

    static func segments(for author: CommentAuthor) -> [Segment] {
        var result: [Segment] = []
        switch author.sex {
        case .male:
            result.append(
                Segment(
                    text: "♂",
                    foreground: .systemBlue,
                    background: nil,
                    stroke: nil,
                    horizontalPadding: 0
                )
            )
        case .female:
            result.append(
                Segment(
                    text: "♀",
                    foreground: .systemPink,
                    background: nil,
                    stroke: nil,
                    horizontalPadding: 0
                )
            )
        case .unspecified:
            break
        }
        if let level = author.level {
            let color = Self.levelColor(level)
            result.append(
                Segment(
                    text: author.isHardcoreMember ? "LV\(level)⚡︎" : "LV\(level)",
                    foreground: .labelColor,
                    background: color.withAlphaComponent(0.16),
                    stroke: color.withAlphaComponent(0.55),
                    horizontalPadding: 3
                )
            )
        } else if author.isHardcoreMember {
            result.append(
                Segment(
                    text: "⚡︎",
                    foreground: .systemOrange,
                    background: NSColor.systemOrange.withAlphaComponent(0.12),
                    stroke: NSColor.systemOrange.withAlphaComponent(0.45),
                    horizontalPadding: 3
                )
            )
        }
        if author.isUploader {
            result.append(
                Segment(
                    text: "UP",
                    foreground: .white,
                    background: NSColor(
                        srgbRed: 142 / 255,
                        green: 18 / 255,
                        blue: 75 / 255,
                        alpha: 1
                    ),
                    stroke: nil,
                    horizontalPadding: 4
                )
            )
        }
        return result
    }

    func reset() {
        segments.removeAll(keepingCapacity: true)
        cachedPreferredWidth = 0
        isHidden = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        var x: CGFloat = 0
        let badgeHeight = min(14, bounds.height)
        let y = floor((bounds.height - badgeHeight) / 2)
        for segment in segments {
            let rect = NSRect(
                x: x,
                y: y,
                width: segment.width,
                height: badgeHeight
            )
            if let background = segment.background {
                background.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            }
            if let stroke = segment.stroke {
                stroke.setStroke()
                let strokeRect = rect.insetBy(dx: 0.5, dy: 0.5)
                NSBezierPath(roundedRect: strokeRect, xRadius: 2, yRadius: 2)
                    .stroke()
            }
            if let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                context.textPosition = NSPoint(
                    x: rect.midX - segment.textSize.width / 2,
                    y: rect.midY - segment.textSize.height / 2
                        + segment.baselineFromTop
                )
                CTLineDraw(segment.textLine, context)
                context.restoreGState()
            }
            x += segment.width + 5
        }
    }

    private static func preferredWidth(segments: [RenderedSegment]) -> CGFloat {
        guard !segments.isEmpty else { return 0 }
        return segments.reduce(CGFloat.zero) { $0 + $1.width }
            + CGFloat(max(0, segments.count - 1)) * 5
    }

    private static func preferredWidth(
        segments: [Segment],
        font: NSFont
    ) -> CGFloat {
        guard !segments.isEmpty else { return 0 }
        return segments.reduce(CGFloat.zero) { width, segment in
            width + segmentWidth(segment, font: font)
        } + CGFloat(max(0, segments.count - 1)) * 5
    }

    private static func segmentWidth(_ segment: Segment, font: NSFont) -> CGFloat {
        ceil(
            (segment.text as NSString).size(withAttributes: [.font: font]).width
                + segment.horizontalPadding * 2
        )
    }

    private static func levelColor(_ level: Int) -> NSColor {
        switch level {
        case ...1: NSColor(srgbRed: 192 / 255, green: 192 / 255, blue: 192 / 255, alpha: 1)
        case 2: NSColor(srgbRed: 139 / 255, green: 210 / 255, blue: 155 / 255, alpha: 1)
        case 3: NSColor(srgbRed: 123 / 255, green: 205 / 255, blue: 239 / 255, alpha: 1)
        case 4: NSColor(srgbRed: 254 / 255, green: 187 / 255, blue: 139 / 255, alpha: 1)
        case 5: NSColor(srgbRed: 238 / 255, green: 103 / 255, blue: 42 / 255, alpha: 1)
        default: NSColor(srgbRed: 240 / 255, green: 76 / 255, blue: 73 / 255, alpha: 1)
        }
    }
}

@MainActor
final class NativePlaybackCommentProvenanceBadgesView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    @MainActor
    private struct RenderedSegment {
        let text: String
        let background: NSColor
        let attributedText: NSAttributedString
        let textSize: NSSize
        let width: CGFloat

        init(text: String, foreground: NSColor, background: NSColor) {
            self.text = text
            self.background = background
            attributedText = NSAttributedString(
                string: text,
                attributes: [
                    .font: NativePlaybackCommentProvenanceBadgesView.font,
                    .foregroundColor: foreground
                ]
            )
            textSize = attributedText.size()
            width = ceil(textSize.width) + 14
        }
    }

    private static let font = NSFont.systemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize,
        weight: .semibold
    )
    private static let pinnedSegment = RenderedSegment(
        text: AppStrings.localized("置顶"),
        foreground: .systemPink,
        background: NSColor.systemPink.withAlphaComponent(0.14)
    )
    private static let uploaderLikedSegment = RenderedSegment(
        text: AppStrings.localized("UP 主觉得很赞"),
        foreground: .secondaryLabelColor,
        background: NSColor.secondaryLabelColor.withAlphaComponent(0.12)
    )
    private var segments: [RenderedSegment] = []
    private(set) var displayedTexts: [String] = []

    func configure(_ provenance: [CommentProvenance]) {
        var result: [RenderedSegment] = []
        if provenance.contains(.adminPinned) || provenance.contains(.uploaderPinned) {
            result.append(Self.pinnedSegment)
        }
        if provenance.contains(.uploaderLiked) {
            result.append(Self.uploaderLikedSegment)
        }
        segments = result
        displayedTexts = result.map(\.text)
        isHidden = result.isEmpty
        setAccessibilityElement(!result.isEmpty)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(
            result.isEmpty
                ? nil : ListFormatter.localizedString(byJoining: displayedTexts)
        )
        needsDisplay = true
    }

    func reset() {
        segments.removeAll(keepingCapacity: true)
        displayedTexts.removeAll(keepingCapacity: true)
        isHidden = true
        setAccessibilityElement(false)
        setAccessibilityLabel(nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        var x: CGFloat = 0
        let height = min(18, bounds.height)
        let y = floor((bounds.height - height) / 2)
        for segment in segments {
            let rect = NSRect(
                x: x,
                y: y,
                width: segment.width,
                height: height
            )
            segment.background.setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: height / 2,
                yRadius: height / 2
            ).fill()
            segment.attributedText.draw(
                at: NSPoint(
                    x: rect.midX - segment.textSize.width / 2,
                    y: rect.midY - segment.textSize.height / 2
                )
            )
            x += segment.width + 6
        }
    }
}
