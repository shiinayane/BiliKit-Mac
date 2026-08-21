import BiliApplication
import BiliBrowseFeature
import Testing

@MainActor
@Suite
struct DanmakuControlsViewModelTests {
    @Test
    @MainActor
    func toggleEnabledUsesExistingPresentationOwner() {
        let presentation = RecordingDanmakuPresentation()
        let model = DanmakuControlsViewModel(presentation: presentation)

        #expect(!model.toggleEnabled())
        #expect(model.toggleEnabled())
        #expect(presentation.enabledValues.suffix(2) == [false, true])
    }

    @Test
    func selectionControlsAndResetReachApplicationPort() throws {
        let presentation = RecordingDanmakuPresentation()
        var savedSpeedLevels: [DanmakuSpeedLevel] = []
        var savedOpacities: [DanmakuOpacity] = []
        var savedDisplayAreas: [DanmakuDisplayArea] = []
        var savedDensities: [DanmakuDensity] = []
        let initialOpacity = try #require(DanmakuOpacity(0.65))
        let model = DanmakuControlsViewModel(
            presentation: presentation,
            initialSpeedLevel: .two,
            initialOpacity: initialOpacity,
            initialDisplayArea: .half,
            initialDensity: .overlapping,
            saveSpeedLevel: { savedSpeedLevels.append($0) },
            saveOpacity: { savedOpacities.append($0) },
            saveDisplayArea: { savedDisplayAreas.append($0) },
            saveDensity: { savedDensities.append($0) }
        )
        let identity = PlaybackItemIdentity(
            bvid: "BV1ControlsFixture",
            cid: 1
        )

        model.selectVideo(identity)
        model.setEnabled(false)
        model.setShowsScrolling(false)
        model.setShowsTop(false)
        model.setShowsBottom(false)
        model.setSpeedLevel(.five)
        model.setOpacity(0.4)
        model.setOpacity(0.1)
        model.setOpacity(.nan)
        model.setDensity(.increased)
        model.setDisplayArea(.full)
        model.setDensity(.increased)
        model.setDisplayArea(.half)
        model.setDensity(.normal)
        presentation.reportAuthenticationInvalidation()
        model.reset()

        #expect(presentation.startedIdentities == [identity])
        #expect(presentation.enabledValues == [false])
        #expect(presentation.speedLevels == [.two, .five])
        #expect(presentation.opacities == [initialOpacity, DanmakuOpacity(0.4)])
        #expect(presentation.displayAreas == [.half, .full, .half])
        #expect(presentation.densities == [.overlapping, .increased])
        #expect(savedSpeedLevels == [.five])
        #expect(savedOpacities == [DanmakuOpacity(0.4)])
        #expect(savedDisplayAreas == [.full, .half])
        #expect(savedDensities == [.increased])
        #expect(
            presentation.modeValues == [
                ModeValues(scrolling: false, top: true, bottom: true),
                ModeValues(scrolling: false, top: false, bottom: true),
                ModeValues(scrolling: false, top: false, bottom: false),
            ]
        )
        #expect(presentation.stopCount == 1)
        #expect(!model.isEnabled)
        #expect(!model.showsScrolling)
        #expect(!model.showsTop)
        #expect(!model.showsBottom)
        #expect(model.speedLevel == .five)
        #expect(model.opacity == DanmakuOpacity(0.4))
        #expect(model.displayArea == .half)
        #expect(model.density == .increased)
        #expect(!model.canAdjustDensity)
        #expect(model.authenticationRevalidationGeneration == 1)
    }
}

private struct ModeValues: Equatable {
    let scrolling: Bool
    let top: Bool
    let bottom: Bool
}

@MainActor
private final class RecordingDanmakuPresentation:
    DanmakuPresentationControlling
{
    private(set) var startedIdentities: [PlaybackItemIdentity] = []
    private(set) var enabledValues: [Bool] = []
    private(set) var modeValues: [ModeValues] = []
    private(set) var speedLevels: [DanmakuSpeedLevel] = []
    private(set) var opacities: [DanmakuOpacity] = []
    private(set) var displayAreas: [DanmakuDisplayArea] = []
    private(set) var densities: [DanmakuDensity] = []
    private(set) var stopCount = 0
    private var authenticationInvalidationHandler: (@MainActor () -> Void)?

    func setAuthenticationInvalidationHandler(
        _ handler: @escaping @MainActor () -> Void
    ) {
        authenticationInvalidationHandler = handler
    }

    func reportAuthenticationInvalidation() {
        authenticationInvalidationHandler?()
    }

    func start(for identity: PlaybackItemIdentity) {
        startedIdentities.append(identity)
    }

    func setEnabled(_ enabled: Bool) {
        enabledValues.append(enabled)
    }

    func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel) {
        speedLevels.append(speedLevel)
    }

    func setOpacity(_ opacity: DanmakuOpacity) {
        opacities.append(opacity)
    }

    func setDisplayArea(_ displayArea: DanmakuDisplayArea) {
        displayAreas.append(displayArea)
    }

    func setDensity(_ density: DanmakuDensity) {
        densities.append(density)
    }

    func setModeVisibility(
        scrolling: Bool,
        top: Bool,
        bottom: Bool
    ) {
        modeValues.append(
            ModeValues(
                scrolling: scrolling,
                top: top,
                bottom: bottom
            )
        )
    }

    func stop() {
        stopCount += 1
    }
}
