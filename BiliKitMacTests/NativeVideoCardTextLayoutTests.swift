import AppKit
import QuartzCore
import Testing

@testable import BiliKit

struct NativeVideoCardTextLayoutTests {
    @Test
    func cardFontCopiesSourceDescriptorWithoutForcingLanguage() {
        let source = NSFont.systemFont(ofSize: 15, weight: .medium)
        let font = NativeVideoCardTextLayout.ctFont(source)
        #expect(CTFontGetSize(font) == source.pointSize)
        let sourceCTFont = CTFontCreateWithFontDescriptor(
            source.fontDescriptor as CTFontDescriptor,
            source.pointSize,
            nil
        )
        #expect(CTFontGetSymbolicTraits(font) == CTFontGetSymbolicTraits(sourceCTFont))
        let sourceWeight =
            (CTFontCopyTraits(sourceCTFont) as NSDictionary)[
                kCTFontWeightTrait
            ] as? NSNumber
        let resolvedWeight =
            (CTFontCopyTraits(font) as NSDictionary)[
                kCTFontWeightTrait
            ] as? NSNumber
        #expect(resolvedWeight == sourceWeight)
    }

    @Test
    func singleLineMeasurementHandlesEmptyAndMixedText() {
        let font = NSFont.preferredFont(forTextStyle: .body)

        #expect(NativeVideoCardTextLayout.singleLineWidth("", font: font) == 0)
        let width = NativeVideoCardTextLayout.singleLineWidth(
            "中日韩 English 👨‍👩‍👧‍👦",
            font: font
        )
        #expect(width.isFinite)
        #expect(width > 0)
    }

    @Test @MainActor
    func rendererUsesPlainStringsAndClearsReusedContent() throws {
        let renderer = NativeVideoCardTextRenderer()
        let parent = CALayer()
        renderer.install(in: parent)
        renderer.configure(
            title: "旧标题 old 👨‍👩‍👧‍👦",
            footerLeading: "旧作者",
            footerTrailing: "昨天"
        )
        let appearance = try #require(NSAppearance(named: .aqua))
        layout(renderer, scale: 2, appearance: appearance)

        #expect(renderer.titleLayer.string as? String == "旧标题 old 👨‍👩‍👧‍👦")
        #expect(renderer.footerLeadingLayer.string as? String == "旧作者")
        #expect(renderer.footerTrailingLayer.string as? String == "昨天")
        #expect(!(renderer.titleLayer.string is NSAttributedString))
        #expect(renderer.titleLayer.isWrapped)
        #expect(renderer.titleLayer.truncationMode == .end)
        #expect(!renderer.footerLeadingLayer.isWrapped)
        #expect(renderer.footerLeadingLayer.truncationMode == .end)
        #expect(renderer.footerTrailingLayer.alignmentMode == .right)
        #expect(renderer.titleLayer.contentsScale == 2)
        let footerFont = renderer.footerTrailingLayer.font as! CTFont
        #expect(
            renderer.trailingWidth(font: .preferredFont(forTextStyle: .body))
                == NativeVideoCardTextLayout.singleLineWidth("昨天", font: footerFont)
        )
        let cachedTitleFont = renderer.titleLayer.font
        let cachedFooterFont = renderer.footerTrailingLayer.font
        layout(renderer, scale: 2, appearance: appearance)
        #expect(renderer.titleLayer.font === cachedTitleFont)
        #expect(renderer.footerTrailingLayer.font === cachedFooterFont)

        renderer.configure(
            title: "新标题",
            footerLeading: "新作者",
            footerTrailing: nil
        )
        layout(renderer, scale: 1, appearance: appearance)
        #expect(renderer.titleLayer.string as? String == "新标题")
        #expect(renderer.footerLeadingLayer.string as? String == "新作者")
        #expect(renderer.footerTrailingLayer.string == nil)
        #expect(renderer.footerTrailingLayer.isHidden)
        #expect(renderer.titleLayer.contentsScale == 1)

        renderer.reset()
        for layer in [
            renderer.titleLayer,
            renderer.footerLeadingLayer,
            renderer.footerTrailingLayer,
        ] {
            #expect(layer.string == nil)
            #expect(layer.isHidden)
            #expect(layer.animationKeys()?.isEmpty ?? true)
        }
    }

    @Test @MainActor
    func recommendationReasonUsesOutlinedBrandCapsuleAndClearsOnReuse() throws {
        let renderer = NativeVideoCardTextRenderer()
        renderer.install(in: CALayer())
        renderer.configure(
            title: "推荐视频",
            footerLeading: "作者",
            footerTrailing: "正在流行",
            footerTrailingStyle: .brandOutlinedCapsule
        )
        let appearance = try #require(NSAppearance(named: .aqua))

        layout(
            renderer,
            scale: 2,
            appearance: appearance,
            footerTrailingFrame: NSRect(x: 152, y: 190.5, width: 72, height: 16)
        )

        #expect(renderer.footerTrailingLayer.alignmentMode == .center)
        #expect(renderer.footerTrailingLayer.borderWidth == 0.5)
        #expect(renderer.footerTrailingLayer.cornerRadius == 8)
        #expect(renderer.footerTrailingLayer.centersTextVertically)
        #expect(renderer.footerTrailingLayer.fontSize == 11)
        #expect(renderer.footerTrailingLayer.frame.minY == 190.5)
        let textOffset = NativeVideoCardTextLayout.recommendationCapsuleTextOffset(
            height: 16,
            fontSize: 11
        )
        #expect(abs(textOffset - 0.62) < 0.001)
        #expect(renderer.footerTrailingLayer.backgroundColor == NSColor.clear.cgColor)
        let border = try #require(renderer.footerTrailingLayer.borderColor)
        let color = NSColor(cgColor: border)?.usingColorSpace(.sRGB)
        #expect(abs((color?.redComponent ?? -1) - 0) < 0.001)
        #expect(abs((color?.greenComponent ?? -1) - 174.0 / 255.0) < 0.001)
        #expect(abs((color?.blueComponent ?? -1) - 236.0 / 255.0) < 0.001)
        let measuredText = NativeVideoCardTextLayout.singleLineWidth(
            "正在流行",
            font: .systemFont(ofSize: 11, weight: .medium)
        )
        let capsuleWidth = renderer.trailingWidth(
            font: .preferredFont(forTextStyle: .body)
        )
        #expect(capsuleWidth == measuredText + 10)

        renderer.configure(
            title: "普通尾注",
            footerLeading: "作者",
            footerTrailing: "正在流行"
        )
        let plainWidth = renderer.trailingWidth(
            font: .preferredFont(forTextStyle: .body)
        )
        #expect(
            plainWidth
                == NativeVideoCardTextLayout.singleLineWidth(
                    "正在流行",
                    font: .preferredFont(forTextStyle: .body)
                )
        )
        #expect(plainWidth != capsuleWidth)

        renderer.configure(
            title: "复用视频",
            footerLeading: "新作者",
            footerTrailing: "昨天"
        )
        layout(renderer, scale: 2, appearance: appearance)
        #expect(renderer.footerTrailingLayer.alignmentMode == .right)
        #expect(renderer.footerTrailingLayer.borderColor == nil)
        #expect(renderer.footerTrailingLayer.borderWidth == 0)
        #expect(renderer.footerTrailingLayer.cornerRadius == 0)
        #expect(!renderer.footerTrailingLayer.centersTextVertically)
    }

    @Test @MainActor
    func cardRetainsAggregatedButtonAccessibilityAcrossReset() {
        let card = NativeVideoCardView(
            frame: NSRect(x: 0, y: 0, width: 224, height: 210)
        )
        card.configure(
            presentation: NativeVideoCardPresentation(
                id: "BV-text-layer",
                title: "标题",
                coverURL: nil,
                avatarURL: nil,
                showsAvatar: false,
                coverMetrics: [],
                coverTrailingText: nil,
                footerLeadingText: "作者",
                footerTrailingText: nil,
                accessibilityLabel: "标题，作者",
                accessibilityHelp: "播放视频"
            ),
            hoverDidChange: { _ in },
            activation: {}
        )

        #expect(card.accessibilityRole() == .button)
        #expect(card.accessibilityLabel() == "标题，作者")
        #expect(card.accessibilityHelp() == "播放视频")

        card.reset()
        #expect(card.accessibilityRole() == .button)
        #expect(card.accessibilityLabel() == nil)
        #expect(card.accessibilityHelp() == nil)
        #expect(card.accessibilityValue() == nil)
    }

    @MainActor
    private func layout(
        _ renderer: NativeVideoCardTextRenderer,
        scale: CGFloat,
        appearance: NSAppearance,
        footerTrailingFrame: NSRect = NSRect(
            x: 152,
            y: 189,
            width: 72,
            height: 21
        )
    ) {
        renderer.layout(
            titleFrame: NSRect(x: 44, y: 136, width: 180, height: 47),
            footerLeadingFrame: NSRect(x: 44, y: 189, width: 100, height: 21),
            footerTrailingFrame: footerTrailingFrame,
            titleFont: .systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize,
                weight: .medium
            ),
            footerFont: .preferredFont(forTextStyle: .body),
            appearance: appearance,
            contentsScale: scale
        )
    }
}
