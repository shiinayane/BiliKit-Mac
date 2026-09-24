import AppKit
import BiliApplication
import BiliBrowseFeature
import BiliModels
import Foundation

@MainActor
struct WatchProgressWindowConnection {
    let start: () -> Void
    let stop: () -> Void
    let setReportingAccess: (Bool) -> Void
}

extension WatchProgressWindowConnection {
    /// 把窗口的观看进度会话接到共享播放时间线与系统睡眠／唤醒通知。
    static func live(
        repository: any WatchProgressRepository,
        timeline: any PlaybackTimelineProviding,
        videoModel: GuestVideoViewModel
    ) -> WatchProgressWindowConnection {
        let session = WatchProgressSession(
            useCase: WatchProgressUseCase(repository: repository),
            timeline: timeline,
            resolveTarget: { [weak videoModel] identity, loadIntent in
                guard let context = videoModel?.presentedContext else { return nil }
                return WatchProgressTargetResolution.resolve(
                    aid: context.detail.aid,
                    bvid: context.detail.bvid,
                    cid: context.selectedPage.cid,
                    identity: identity,
                    loadIntent: loadIntent
                )
            }
        )
        let sleepObservation = WatchProgressSleepObservation(
            suspend: { session.suspend() },
            resume: { session.resumeAfterSuspension() }
        )
        return WatchProgressWindowConnection(
            start: {
                session.start()
                sleepObservation.start()
            },
            stop: {
                sleepObservation.stop()
                session.stop()
            },
            setReportingAccess: { session.setReportingAccess(signedIn: $0) }
        )
    }
}

enum WatchProgressTargetResolution {
    static func resolve(
        aid: Int64?,
        bvid: String,
        cid: Int64,
        identity: PlaybackItemIdentity,
        loadIntent: PlaybackLoadIntent
    ) -> WatchProgressTarget? {
        guard bvid == identity.bvid, cid == identity.cid, let aid else {
            return nil
        }
        return WatchProgressTarget(
            aid: aid,
            identity: identity,
            loadIntent: loadIntent
        )
    }
}

@MainActor
private final class WatchProgressSleepObservation {
    private let suspend: () -> Void
    private let resume: () -> Void
    private var observers: [NSObjectProtocol] = []

    init(suspend: @escaping () -> Void, resume: @escaping () -> Void) {
        self.suspend = suspend
        self.resume = resume
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.suspend() }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.resume() }
            }
        ]
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll(keepingCapacity: false)
    }
}
