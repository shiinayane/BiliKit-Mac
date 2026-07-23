import Foundation
import QuartzCore

final class AnimationCompletionRelay: NSObject, CAAnimationDelegate {
    weak var renderer: CoreAnimationDanmakuRenderer?
    let eventID: String
    let objectIdentity: UInt64
    let renderEpoch: UInt64

    init(
        renderer: CoreAnimationDanmakuRenderer,
        eventID: String,
        objectIdentity: UInt64,
        renderEpoch: UInt64
    ) {
        self.renderer = renderer
        self.eventID = eventID
        self.objectIdentity = objectIdentity
        self.renderEpoch = renderEpoch
    }

    nonisolated func animationDidStop(
        _ animation: CAAnimation,
        finished flag: Bool
    ) {
        let renderer = renderer
        let eventID = eventID
        let objectIdentity = objectIdentity
        let renderEpoch = renderEpoch
        Task { @MainActor [weak renderer] in
            renderer?.completeAnimation(
                eventID: eventID,
                objectIdentity: objectIdentity,
                renderEpoch: renderEpoch
            )
        }
    }
}
