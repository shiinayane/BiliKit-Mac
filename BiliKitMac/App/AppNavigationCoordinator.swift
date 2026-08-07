import Foundation
import Observation

enum AppTab: Hashable {
    case search
    case popular
    case history
}

struct PlaybackDestination: Hashable {
    let surfaceID: UUID
}

private struct ActivePlayback: Equatable {
    let destination: PlaybackDestination
    var bvid: String
}

@MainActor
@Observable
/// 协调窗口内的顶层 Tab、原生导航路径与播放生命周期副作用。
///
/// Coordinator 不拥有播放器；typed path 只表达是否位于播放层级，当前 BVID 则表达该
/// 层级内的媒体 identity。系统返回、切换来源与关窗都通过同一条播放副作用边界收口。
final class AppNavigationCoordinator {
    var selectedTab: AppTab = .popular {
        didSet {
            guard selectedTab != oldValue else { return }
            closePlayback()
        }
    }
    var playbackPath: [PlaybackDestination] {
        get {
            activePlayback.map { [$0.destination] } ?? []
        }
        set {
            // 只有 openPlayback 可以建立播放 surface；系统 path 写回只负责 pop。
            guard newValue.isEmpty else { return }
            closePlayback()
        }
    }
    var currentPlaybackBVID: String? {
        activePlayback?.bvid
    }
    var searchDraft = ""

    private var activePlayback: ActivePlayback?
    @ObservationIgnored private let startPlayback: (String) -> Void
    @ObservationIgnored private let stopPlayback: () -> Void

    init(
        startPlayback: @escaping (String) -> Void,
        stopPlayback: @escaping () -> Void
    ) {
        self.startPlayback = startPlayback
        self.stopPlayback = stopPlayback
    }

    /// 首次打开建立播放 surface；连续打开其他视频只替换媒体 identity。
    func openPlayback(_ bvid: String) {
        guard !bvid.isEmpty else { return }
        guard currentPlaybackBVID != bvid else { return }

        if var activePlayback {
            activePlayback.bvid = bvid
            self.activePlayback = activePlayback
        } else {
            activePlayback = ActivePlayback(
                destination: PlaybackDestination(surfaceID: UUID()),
                bvid: bvid
            )
        }
        startPlayback(bvid)
    }

    func retryPlayback() {
        guard let bvid = currentPlaybackBVID else { return }
        startPlayback(bvid)
    }

    /// 登出只关闭当前播放，不改变来源 Tab 或尚未提交的搜索草稿。
    func closePlaybackForAuthenticationChange() {
        closePlayback()
    }

    /// 关闭当前播放，并恢复一个新窗口应有的来源与搜索草稿。
    func resetForWindowClosure() {
        closePlayback()
        selectedTab = .popular
        searchDraft = ""
    }

    private func closePlayback() {
        guard activePlayback != nil else { return }
        activePlayback = nil
        stopPlayback()
    }
}
