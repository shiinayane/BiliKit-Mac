import BiliApplication
import BiliBrowseFeature
import Testing

@MainActor
@Suite
struct DanmakuControlsViewModelTests {
    @Test
    func selectionControlsAndResetReachApplicationPort() throws {
        let presentation = RecordingDanmakuPresentation()
        var savedSpeedLevels: [DanmakuSpeedLevel] = []
        var savedOpacities: [DanmakuOpacity] = []
        let initialOpacity = try #require(DanmakuOpacity(0.65))
        let model = DanmakuControlsViewModel(
            presentation: presentation,
            initialSpeedLevel: .two,
            initialOpacity: initialOpacity,
            saveSpeedLevel: { savedSpeedLevels.append($0) },
            saveOpacity: { savedOpacities.append($0) }
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
        model.reset()

        #expect(presentation.startedIdentities == [identity])
        #expect(presentation.enabledValues == [false])
        #expect(presentation.speedLevels == [.two, .five])
        #expect(presentation.opacities == [initialOpacity, DanmakuOpacity(0.4)])
        #expect(savedSpeedLevels == [.five])
        #expect(savedOpacities == [DanmakuOpacity(0.4)])
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
    private(set) var stopCount = 0

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
