import AppKit
import CoreText
import QuartzCore

enum NativeVideoCardTextLayout {
    static let typesettingLanguage = "zh-Hans"

    static func singleLineWidth(
        _ text: String,
        font: NSFont
    ) -> CGFloat {
        singleLineWidth(text, font: languageAwareCTFont(font))
    }

    static func singleLineWidth(
        _ text: String,
        font: CTFont
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text,
                attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: font
                ]
            )
        )
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    static func languageAwareCTFont(_ font: NSFont) -> CTFont {
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            font.fontDescriptor as CTFontDescriptor,
            [
                kCTFontDescriptorLanguageAttribute: typesettingLanguage
            ] as CFDictionary
        )
        return CTFontCreateWithFontDescriptor(
            descriptor,
            font.pointSize,
            nil
        )
    }

    nonisolated(unsafe) static let disabledLayerActions: [String: CAAction] = [
        "bounds": NSNull(),
        "contents": NSNull(),
        "font": NSNull(),
        "fontSize": NSNull(),
        "foregroundColor": NSNull(),
        "hidden": NSNull(),
        "position": NSNull(),
        "string": NSNull(),
    ]
}

@MainActor
final class NativeVideoCardTextRenderer {
    let titleLayer = NativeVideoCardTextRenderer.makeTextLayer(isWrapped: true)
    let footerLeadingLayer = NativeVideoCardTextRenderer.makeTextLayer(isWrapped: false)
    let footerTrailingLayer = NativeVideoCardTextRenderer.makeTextLayer(
        isWrapped: false,
        alignmentMode: .right
    )

    private var title = ""
    private var footerLeading = ""
    private var footerTrailing: String?
    private var footerTrailingWidthCache = NativeVideoSingleLineWidthCache()
    private var cachedTitleFont: (source: NSFont, resolved: CTFont)?
    private var cachedFooterFont: (source: NSFont, resolved: CTFont)?

    var showsFooterTrailing: Bool { footerTrailing != nil }

    func install(in parentLayer: CALayer) {
        parentLayer.addSublayer(titleLayer)
        parentLayer.addSublayer(footerLeadingLayer)
        parentLayer.addSublayer(footerTrailingLayer)
        reset()
    }

    func configure(
        title: String,
        footerLeading: String,
        footerTrailing: String?
    ) {
        self.title = title
        self.footerLeading = footerLeading
        self.footerTrailing = footerTrailing
    }

    func reset() {
        title = ""
        footerLeading = ""
        footerTrailing = nil
        footerTrailingWidthCache.reset()
        for textLayer in [titleLayer, footerLeadingLayer, footerTrailingLayer] {
            textLayer.removeAllAnimations()
            textLayer.string = nil
            textLayer.isHidden = true
        }
    }

    func trailingWidth(font: NSFont) -> CGFloat {
        guard let footerTrailing else { return 0 }
        let font = resolvedFooterFont(for: font)
        return footerTrailingWidthCache.width(for: footerTrailing) {
            NativeVideoCardTextLayout.singleLineWidth(footerTrailing, font: font)
        }
    }

    func layout(
        titleFrame: NSRect,
        footerLeadingFrame: NSRect,
        footerTrailingFrame: NSRect,
        titleFont: NSFont,
        footerFont: NSFont,
        appearance: NSAppearance,
        contentsScale: CGFloat
    ) {
        let colors = Self.resolvedColors(appearance: appearance)
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        titleLayer.frame = titleFrame
        titleLayer.contentsScale = contentsScale
        titleLayer.font = resolvedTitleFont(for: titleFont)
        titleLayer.fontSize = titleFont.pointSize
        titleLayer.foregroundColor = colors.title.cgColor
        titleLayer.string = title.isEmpty ? nil : title
        titleLayer.isHidden = title.isEmpty

        let footerCTFont = resolvedFooterFont(for: footerFont)
        for footerLayer in [footerLeadingLayer, footerTrailingLayer] {
            footerLayer.contentsScale = contentsScale
            footerLayer.font = footerCTFont
            footerLayer.fontSize = footerFont.pointSize
            footerLayer.foregroundColor = colors.footer.cgColor
        }
        footerLeadingLayer.frame = footerLeadingFrame
        footerLeadingLayer.string = footerLeading.isEmpty ? nil : footerLeading
        footerLeadingLayer.isHidden = footerLeading.isEmpty
        footerTrailingLayer.frame = footerTrailingFrame
        footerTrailingLayer.string = footerTrailing
        footerTrailingLayer.isHidden = footerTrailing == nil

        CATransaction.commit()
    }

    private func resolvedTitleFont(for font: NSFont) -> CTFont {
        if let cachedTitleFont, cachedTitleFont.source == font {
            return cachedTitleFont.resolved
        }
        let resolved = NativeVideoCardTextLayout.languageAwareCTFont(font)
        cachedTitleFont = (font, resolved)
        return resolved
    }

    private func resolvedFooterFont(for font: NSFont) -> CTFont {
        if let cachedFooterFont, cachedFooterFont.source == font {
            return cachedFooterFont.resolved
        }
        let resolved = NativeVideoCardTextLayout.languageAwareCTFont(font)
        cachedFooterFont = (font, resolved)
        footerTrailingWidthCache.reset()
        return resolved
    }

    private static func makeTextLayer(
        isWrapped: Bool,
        alignmentMode: CATextLayerAlignmentMode = .left
    ) -> CATextLayer {
        let textLayer = CATextLayer()
        textLayer.isWrapped = isWrapped
        textLayer.truncationMode = .end
        textLayer.alignmentMode = alignmentMode
        textLayer.actions = NativeVideoCardTextLayout.disabledLayerActions
        return textLayer
    }

    private static func resolvedColors(
        appearance: NSAppearance
    ) -> (title: NSColor, footer: NSColor) {
        var title = NSColor.labelColor
        var footer = NSColor.secondaryLabelColor
        appearance.performAsCurrentDrawingAppearance {
            title = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .labelColor
            footer = NSColor.secondaryLabelColor.usingColorSpace(.deviceRGB) ?? .secondaryLabelColor
        }
        return (title, footer)
    }
}
