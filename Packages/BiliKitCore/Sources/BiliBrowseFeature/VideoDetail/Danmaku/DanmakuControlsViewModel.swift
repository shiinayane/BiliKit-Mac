import BiliApplication
import Observation

@MainActor
@Observable
/// 只保存用户可见的弹幕开关，并把视频 lifecycle 交给 presentation port。
///
/// 它不拥有 protobuf、分段缓存、时间线或 renderer；`reset` 必须停止整条会话而非只隐藏画面。
public final class DanmakuControlsViewModel {
    public private(set) var isEnabled = true
    public private(set) var showsScrolling = true
    public private(set) var showsTop = true
    public private(set) var showsBottom = true
    public private(set) var speedLevel: DanmakuSpeedLevel
    public private(set) var opacity: DanmakuOpacity
    public private(set) var displayArea: DanmakuDisplayArea
    public private(set) var density: DanmakuDensity
    public private(set) var authenticationRevalidationGeneration = 0

    public var canAdjustDensity: Bool {
        displayArea == .full
    }

    @ObservationIgnored
    private let presentation: any DanmakuPresentationControlling
    @ObservationIgnored
    private let saveSpeedLevel: @MainActor (DanmakuSpeedLevel) -> Void
    @ObservationIgnored
    private let saveOpacity: @MainActor (DanmakuOpacity) -> Void
    @ObservationIgnored
    private let saveDisplayArea: @MainActor (DanmakuDisplayArea) -> Void
    @ObservationIgnored
    private let saveDensity: @MainActor (DanmakuDensity) -> Void

    public init(
        presentation: any DanmakuPresentationControlling,
        initialSpeedLevel: DanmakuSpeedLevel = .three,
        initialOpacity: DanmakuOpacity = .fullyOpaque,
        initialDisplayArea: DanmakuDisplayArea = .full,
        initialDensity: DanmakuDensity = .normal,
        saveSpeedLevel: @escaping @MainActor (DanmakuSpeedLevel) -> Void = { _ in },
        saveOpacity: @escaping @MainActor (DanmakuOpacity) -> Void = { _ in },
        saveDisplayArea: @escaping @MainActor (DanmakuDisplayArea) -> Void = { _ in },
        saveDensity: @escaping @MainActor (DanmakuDensity) -> Void = { _ in }
    ) {
        self.presentation = presentation
        self.speedLevel = initialSpeedLevel
        self.opacity = initialOpacity
        self.displayArea = initialDisplayArea
        self.density = initialDensity
        self.saveSpeedLevel = saveSpeedLevel
        self.saveOpacity = saveOpacity
        self.saveDisplayArea = saveDisplayArea
        self.saveDensity = saveDensity
        presentation.setSpeedLevel(initialSpeedLevel)
        presentation.setOpacity(initialOpacity)
        presentation.setDisplayArea(initialDisplayArea)
        presentation.setDensity(initialDensity)
        presentation.setAuthenticationInvalidationHandler { [weak self] in
            self?.authenticationRevalidationGeneration &+= 1
        }
    }

    public func selectVideo(_ identity: PlaybackItemIdentity) {
        presentation.start(for: identity)
    }

    public func reset() {
        presentation.stop()
    }

    public func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        presentation.setEnabled(enabled)
    }

    public func setShowsScrolling(_ shows: Bool) {
        guard showsScrolling != shows else { return }
        showsScrolling = shows
        applyModeVisibility()
    }

    public func setShowsTop(_ shows: Bool) {
        guard showsTop != shows else { return }
        showsTop = shows
        applyModeVisibility()
    }

    public func setShowsBottom(_ shows: Bool) {
        guard showsBottom != shows else { return }
        showsBottom = shows
        applyModeVisibility()
    }

    public func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel) {
        guard self.speedLevel != speedLevel else { return }
        self.speedLevel = speedLevel
        presentation.setSpeedLevel(speedLevel)
        saveSpeedLevel(speedLevel)
    }

    public func setOpacity(_ value: Double) {
        guard let opacity = DanmakuOpacity(value), self.opacity != opacity else {
            return
        }
        self.opacity = opacity
        presentation.setOpacity(opacity)
        saveOpacity(opacity)
    }

    public func setDisplayArea(_ displayArea: DanmakuDisplayArea) {
        guard self.displayArea != displayArea else { return }
        self.displayArea = displayArea
        presentation.setDisplayArea(displayArea)
        saveDisplayArea(displayArea)
    }

    public func setDensity(_ density: DanmakuDensity) {
        guard canAdjustDensity, self.density != density else { return }
        self.density = density
        presentation.setDensity(density)
        saveDensity(density)
    }

    private func applyModeVisibility() {
        presentation.setModeVisibility(
            scrolling: showsScrolling,
            top: showsTop,
            bottom: showsBottom
        )
    }
}
