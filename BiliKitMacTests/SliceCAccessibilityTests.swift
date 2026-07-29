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
}
