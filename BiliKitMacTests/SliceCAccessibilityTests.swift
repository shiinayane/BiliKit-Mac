import AppKit
import SwiftUI
import Testing
@testable import BiliKit

struct SliceCAccessibilityTests {
    @Test
    func uiFixtureRequiresExplicitArgumentAndParsesDisplayPair() {
        let live = UITestConfiguration.parse(arguments: [])
        #expect(!live.isEnabled)
        #expect(!live.usesCompactWindow)
        #expect(!live.usesDarkAppearance)
        #expect(!live.usesLargeText)

        let isolatedHelperFlags = UITestConfiguration.parse(
            arguments: [
                "-ui-testing-compact",
                "-ui-testing-dark",
                "-ui-testing-large-text",
            ]
        )
        #expect(!isolatedHelperFlags.isEnabled)
        #expect(!isolatedHelperFlags.usesCompactWindow)
        #expect(!isolatedHelperFlags.usesDarkAppearance)
        #expect(!isolatedHelperFlags.usesLargeText)

        let fixture = UITestConfiguration.parse(
            arguments: [
                "-ui-testing",
                "-ui-testing-compact",
                "-ui-testing-dark",
                "-ui-testing-large-text",
            ]
        )
        #expect(fixture.isEnabled)
        #expect(fixture.usesCompactWindow)
        #expect(fixture.usesDarkAppearance)
        #expect(fixture.usesLargeText)
    }

    @Test
    @MainActor
    func appKitSearchFieldPublishesLabelHelpAndIdentifier() {
        let hostingView = NSHostingView(
            rootView: CenteredSearchField(
                text: .constant(""),
                placeholder: "搜索 B 站视频",
                onSubmit: {}
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 340, height: 40)
        hostingView.layoutSubtreeIfNeeded()

        guard let searchField = firstSubview(
            of: NSSearchField.self,
            in: hostingView
        ) else {
            Issue.record("missing NSSearchField")
            return
        }
        #expect(searchField.accessibilityLabel() == "搜索 B 站视频")
        #expect(
            searchField.accessibilityHelp()
                == "输入关键词并按 Return 搜索"
        )
        #expect(searchField.accessibilityIdentifier() == "search.field")
    }

    @MainActor
    private func firstSubview<ViewType: NSView>(
        of type: ViewType.Type,
        in root: NSView
    ) -> ViewType? {
        if let match = root as? ViewType {
            return match
        }
        for child in root.subviews {
            if let match = firstSubview(of: type, in: child) {
                return match
            }
        }
        return nil
    }
}
