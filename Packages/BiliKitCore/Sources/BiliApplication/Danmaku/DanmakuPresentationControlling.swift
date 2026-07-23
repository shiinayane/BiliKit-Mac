@MainActor
public protocol DanmakuPresentationControlling: AnyObject {
    func start(for identity: PlaybackItemIdentity)
    func setEnabled(_ enabled: Bool)
    func setModeVisibility(
        scrolling: Bool,
        top: Bool,
        bottom: Bool
    )
    func stop()
}
