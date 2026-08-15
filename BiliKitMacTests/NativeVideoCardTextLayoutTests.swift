import AppKit
import QuartzCore
import Testing

@testable import BiliKit

struct NativeVideoCardTextLayoutTests {
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
        appearance: NSAppearance
    ) {
        renderer.layout(
            titleFrame: NSRect(x: 44, y: 136, width: 180, height: 47),
            footerLeadingFrame: NSRect(x: 44, y: 189, width: 100, height: 21),
            footerTrailingFrame: NSRect(x: 152, y: 189, width: 72, height: 21),
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
