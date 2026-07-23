import BiliApplication
import BiliBrowseFeature
import Testing

@MainActor
@Suite
struct DanmakuControlsViewModelTests {
    @Test
    func selectionControlsAndResetReachApplicationPort() {
        let presentation = RecordingDanmakuPresentation()
        let model = DanmakuControlsViewModel(presentation: presentation)
        let identity = PlaybackItemIdentity(
            bvid: "BV1ControlsFixture",
            cid: 1
        )

        model.selectVideo(identity)
        model.setEnabled(false)
        model.setShowsScrolling(false)
        model.setShowsTop(false)
        model.setShowsBottom(false)
        model.reset()

        #expect(presentation.startedIdentities == [identity])
        #expect(presentation.enabledValues == [false])
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
    private(set) var stopCount = 0

    func start(for identity: PlaybackItemIdentity) {
        startedIdentities.append(identity)
    }

    func setEnabled(_ enabled: Bool) {
        enabledValues.append(enabled)
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
