public enum DanmakuSpeedLevel: Int, CaseIterable, Sendable, Equatable {
    case one = 1
    case two
    case three
    case four
    case five
}

public enum DanmakuDisplayArea: Int, CaseIterable, Sendable, Equatable {
    case ten = 10
    case quarter = 25
    case half = 50
    case threeQuarters = 75
    case full = 100

    public var fraction: Double {
        Double(rawValue) / 100
    }
}

public enum DanmakuDensity: Int, CaseIterable, Sendable, Equatable {
    case normal
    case increased
    case overlapping
}

public struct DanmakuOpacity: Sendable, Equatable {
    public static let allowedRange = 0.2...1.0
    public static let fullyOpaque = DanmakuOpacity(validatedValue: 1)

    public let value: Double

    public init?(_ value: Double) {
        guard value.isFinite, Self.allowedRange.contains(value) else {
            return nil
        }
        self.init(validatedValue: value)
    }

    private init(validatedValue: Double) {
        value = validatedValue
    }
}

@MainActor
/// 让 Feature 驱动弹幕会话开始、可见性与完整停止，而不暴露 scheduler 或 renderer。
public protocol DanmakuPresentationControlling: AnyObject {
    func setAuthenticationInvalidationHandler(
        _ handler: @escaping @MainActor () -> Void
    )
    func start(for identity: PlaybackItemIdentity)
    func setEnabled(_ enabled: Bool)
    func setModeVisibility(
        scrolling: Bool,
        top: Bool,
        bottom: Bool
    )
    func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel)
    func setOpacity(_ opacity: DanmakuOpacity)
    func setDisplayArea(_ displayArea: DanmakuDisplayArea)
    func setDensity(_ density: DanmakuDensity)
    func stop()
}

extension DanmakuPresentationControlling {
    public func setAuthenticationInvalidationHandler(
        _ handler: @escaping @MainActor () -> Void
    ) {}
}
