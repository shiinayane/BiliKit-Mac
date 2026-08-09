public enum DanmakuSpeedLevel: Int, CaseIterable, Sendable, Equatable {
    case one = 1
    case two
    case three
    case four
    case five
}

@MainActor
/// 让 Feature 驱动弹幕会话开始、可见性与完整停止，而不暴露 scheduler 或 renderer。
public protocol DanmakuPresentationControlling: AnyObject {
    func start(for identity: PlaybackItemIdentity)
    func setEnabled(_ enabled: Bool)
    func setModeVisibility(
        scrolling: Bool,
        top: Bool,
        bottom: Bool
    )
    func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel)
    func stop()
}
