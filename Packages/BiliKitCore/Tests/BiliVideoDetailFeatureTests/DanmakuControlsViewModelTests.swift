import BiliApplication
import BiliModels
import BiliVideoDetailFeature
import Testing

/// 弹幕控制项只把有效且有变化的设置交给弹幕会话，并只保存用户改动过的值。
///
/// 初始偏好在创建时下发一次；超出范围或非有限的透明度被忽略；密度只在全屏显示区域可调；三类显示模式合并后整体
/// 下发；选视频启动会话、重置停止会话，会话报告认证失效时递增重新校验 generation。
@MainActor
@Suite
struct DanmakuControlsViewModelTests {
    @Test
    func invalidOrUnchangedValuesAreNeitherAppliedNorSaved() throws {
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

        model.setSpeedLevel(.two)
        model.setSpeedLevel(.five)
        model.setOpacity(0.4)
        model.setOpacity(0.4)
        model.setOpacity(0.1)
        model.setOpacity(.nan)

        #expect(presentation.speedLevels == [.two, .five])
        #expect(presentation.opacities == [initialOpacity, DanmakuOpacity(0.4)])
        #expect(savedSpeedLevels == [.five])
        #expect(savedOpacities == [DanmakuOpacity(0.4)])
        #expect(model.opacity == DanmakuOpacity(0.4))
    }

    @Test
    func densityIsAdjustableOnlyForFullDisplayArea() {
        let presentation = RecordingDanmakuPresentation()
        var savedDisplayAreas: [DanmakuDisplayArea] = []
        var savedDensities: [DanmakuDensity] = []
        let model = DanmakuControlsViewModel(
            presentation: presentation,
            initialDisplayArea: .half,
            initialDensity: .overlapping,
            saveDisplayArea: { savedDisplayAreas.append($0) },
            saveDensity: { savedDensities.append($0) }
        )

        model.setDensity(.increased)
        #expect(!model.canAdjustDensity)
        model.setDisplayArea(.full)
        model.setDensity(.increased)
        model.setDisplayArea(.half)
        model.setDensity(.normal)

        #expect(presentation.densities == [.overlapping, .increased])
        #expect(presentation.displayAreas == [.half, .full, .half])
        #expect(savedDensities == [.increased])
        #expect(savedDisplayAreas == [.full, .half])
        #expect(model.density == .increased)
    }

    @Test
    func duplicateMergingStartsFromThePreferenceAndOnlyChangesAreSaved() {
        let presentation = RecordingDanmakuPresentation()
        var saved: [Bool] = []
        let model = DanmakuControlsViewModel(
            presentation: presentation,
            initialMergesDuplicates: true,
            saveMergesDuplicates: { saved.append($0) }
        )

        model.setMergesDuplicates(true)
        model.setMergesDuplicates(false)
        model.setMergesDuplicates(false)

        #expect(presentation.mergesDuplicatesValues == [true, false])
        #expect(saved == [false])
        #expect(!model.mergesDuplicates)
    }

    @Test
    func modeVisibilityAndSessionLifecycleReachPresentationPort() {
        let presentation = RecordingDanmakuPresentation()
        let model = DanmakuControlsViewModel(presentation: presentation)
        let identity = PlaybackItemIdentity(bvid: "BV1ControlsFixture", cid: 1)

        model.selectVideo(identity)
        model.setShowsScrolling(false)
        model.setShowsTop(false)
        model.setShowsTop(false)
        presentation.reportAuthenticationInvalidation()
        model.reset()

        #expect(presentation.startedIdentities == [identity])
        #expect(
            presentation.modeValues == [
                ModeValues(scrolling: false, top: true, bottom: true),
                ModeValues(scrolling: false, top: false, bottom: true)
            ]
        )
        #expect(model.authenticationRevalidationGeneration == 1)
        #expect(presentation.stopCount == 1)
    }
}

struct ModeValues: Equatable {
    let scrolling: Bool
    let top: Bool
    let bottom: Bool
}

/// 本 target 唯一的 `DanmakuSessionControlling` 替身：记录交给弹幕会话的每项设置、生命周期与本地上屏的弹幕。
@MainActor
final class RecordingDanmakuPresentation:
    DanmakuSessionControlling
{
    private(set) var startedIdentities: [PlaybackItemIdentity] = []
    private(set) var modeValues: [ModeValues] = []
    private(set) var speedLevels: [DanmakuSpeedLevel] = []
    private(set) var opacities: [DanmakuOpacity] = []
    private(set) var displayAreas: [DanmakuDisplayArea] = []
    private(set) var densities: [DanmakuDensity] = []
    private(set) var mergesDuplicatesValues: [Bool] = []
    private(set) var stopCount = 0
    private(set) var ownDanmaku: [(event: DanmakuEvent, identity: PlaybackItemIdentity)] = []
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

    func setEnabled(_ enabled: Bool) {}

    func presentOwnDanmaku(_ event: DanmakuEvent, for identity: PlaybackItemIdentity) {
        ownDanmaku.append((event, identity))
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

    func setMergesDuplicates(_ merges: Bool) {
        mergesDuplicatesValues.append(merges)
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
