import AVKit
import BiliDanmaku
import BiliPlayback
import BiliVideoDetailFeature
import SwiftUI

/// 把窗口常驻的播放器宿主 `NativePlayerHostView` 交给 SwiftUI 布局的 representable：自己只是一个容器，挂载时从
/// `PlayerHostOwner` 取宿主放进来，并把 SwiftUI 侧的回调与提示同步给它；卸载时只把宿主摘下，不拆除。
///
/// 只由 `PlayerHostView` 使用。宿主的创建只在 owner 第一次要它时发生（`makeHost`）；拆除在关窗时由 owner 进行，
/// 只有关窗后迟到的挂载拿到的不留住的宿主才在这里的卸载时拆除。同一时刻只有一个容器持有宿主：新容器挂载时把宿主从旧
/// 容器里取走，旧容器之后的更新与卸载都找不到它，不动作。
struct AVPlayerContainerView: NSViewRepresentable {
    let player: SeekTrackingPlayer
    let renderer: CoreAnimationDanmakuRenderer
    let controller: DanmakuPresentationController
    let blocksNativePlaybackInteraction: Bool
    let resumeNotice: PlaybackResumeNotice?
    let previewEndedNotice: String?
    let restartFromBeginning: () -> Void
    let beginMomentaryPlaybackRate: ((Float) -> UUID?)?
    let endMomentaryPlaybackRate: ((UUID) -> Void)?
    let seekByTransportOffset: ((Double) -> Bool)?
    let adjustVolume: ((Float) -> Float)?
    let togglePlayback: (() -> Bool?)?
    let toggleDanmaku: (() -> Bool)?
    let toggleSubtitles: (() async -> NativeSubtitleToggleResult)?
    let engagementShortcuts: PlayerEngagementShortcuts?
    let danmakuComposer: DanmakuComposerModel?
    let openDanmakuLinkedVideo: ((String) -> Void)?
    let actionMenu: PlayerActionMenuActions
    let playbackEnd: PlayerPlaybackEndActions
    let chapterAnnouncements: NativePlayerHostView.ChapterAnnouncementObserving
    let focusIdentity: String?
    let hdrEnvironment: PlaybackHDREnvironment
    let hostOwner: PlayerHostOwner

    /// 以窗口的 owner 作 coordinator：`dismantleNSView` 是静态方法，只能经 coordinator 拿到 owner，判断卸载的宿主是
    /// 只摘下还是整个拆除。
    func makeCoordinator() -> PlayerHostOwner {
        hostOwner
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let host = hostOwner.host { makeHost() }
        host.removeFromSuperview()
        host.mountInPage(playbackEnd: playbackEnd, chapterAnnouncements: chapterAnnouncements)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        update(host, context: context)
        return container
    }

    /// 窗口第一次需要宿主时创建，并做不随页面变化的配置：挂上 player、原生全屏与画中画开关、HDR 登记；其余随页面
    /// 变化的回调与提示由每次的 `update` 同步。
    private func makeHost() -> NativePlayerHostView {
        let view = NativePlayerHostView(
            renderer: renderer,
            controller: controller,
            beginMomentaryPlaybackRate: beginMomentaryPlaybackRate,
            endMomentaryPlaybackRate: endMomentaryPlaybackRate,
            seekByTransportOffset: seekByTransportOffset,
            adjustVolume: adjustVolume,
            togglePlayback: togglePlayback,
            toggleDanmaku: toggleDanmaku,
            toggleSubtitles: toggleSubtitles
        )
        view.attachPlayer(player)
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        hdrEnvironment.playerView = view
        return view
    }

    /// 给了确定的宽高就直接采用：播放器总是铺满布局给它的区域，不需要 SwiftUI 量它的固有尺寸。
    ///
    /// 不实现时，SwiftUI 每次布局都经 Auto Layout 量一遍 `AVPlayerView` 连同原生控制条的整棵约束；控制条的剩余
    /// 时间每变一次（播放每秒一次、倍速更频繁、拖进度条时连续）都让固有尺寸失效，主线程跟着重量一遍。宽或高未定
    /// 的询问（理想尺寸）返回 nil，沿用系统的测量。
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let host = Self.host(in: container) else { return }
        update(host, context: context)
    }

    private func update(_ view: NativePlayerHostView, context: Context) {
        view.setPlaybackPreparationBlocked(blocksNativePlaybackInteraction)
        view.requestMomentaryPlaybackRate = beginMomentaryPlaybackRate
        view.finishMomentaryPlaybackRate = endMomentaryPlaybackRate
        view.seekByTransportOffset = seekByTransportOffset
        view.adjustVolume = adjustVolume
        view.togglePlayback = togglePlayback
        view.toggleDanmaku = toggleDanmaku
        view.toggleSubtitles = toggleSubtitles
        view.engagementShortcuts = engagementShortcuts
        view.danmakuComposer = danmakuComposer
        view.danmakuOverlay.openLinkedVideo = openDanmakuLinkedVideo
        view.setActionMenu(actionMenu, openURL: context.environment.openURL)
        view.setResumeNotice(
            resumeNotice,
            restartFromBeginning: restartFromBeginning
        )
        view.setPreviewEndedNotice(previewEndedNotice)
        view.requestInitialKeyboardFocus(for: focusIdentity)
        if view.player !== player {
            view.cancelMomentaryPlaybackRate()
            view.attachPlayer(player)
        }
    }

    /// SwiftUI 卸载容器时只把常驻宿主摘下；不留住的宿主（关窗后迟到的挂载）整个拆除。
    static func dismantleNSView(
        _ container: NSView,
        coordinator owner: PlayerHostOwner
    ) {
        guard let host = host(in: container) else { return }
        if owner.retains(host) {
            host.unmountFromPage()
        } else {
            host.tearDown()
        }
        host.removeFromSuperview()
    }

    private static func host(in container: NSView) -> NativePlayerHostView? {
        container.subviews.first as? NativePlayerHostView
    }
}
