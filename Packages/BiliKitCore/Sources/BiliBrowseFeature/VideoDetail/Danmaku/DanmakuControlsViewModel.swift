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

    @ObservationIgnored
    private let presentation: any DanmakuPresentationControlling

    public init(presentation: any DanmakuPresentationControlling) {
        self.presentation = presentation
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

    private func applyModeVisibility() {
        presentation.setModeVisibility(
            scrolling: showsScrolling,
            top: showsTop,
            bottom: showsBottom
        )
    }
}
