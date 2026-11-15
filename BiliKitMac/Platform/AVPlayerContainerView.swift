import AVKit
import BiliDanmaku
import BiliPlayback
import BiliVideoDetailFeature
import SwiftUI

/// 把窗口播放器宿主 `NativePlayerHostView` 交给 SwiftUI 布局的 representable：创建宿主、把 SwiftUI 侧的回调与提示
/// 同步给它，并在 SwiftUI 拆除时按顺序断开。
///
/// 只由 `PlayerHostView` 使用；宿主本身的职责与拆除顺序见 `NativePlayerHostView`。
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
    let focusIdentity: String?
    let hdrEnvironment: PlaybackHDREnvironment

    func makeNSView(context: Context) -> NativePlayerHostView {
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
        view.engagementShortcuts = engagementShortcuts
        view.danmakuComposer = danmakuComposer
        view.danmakuOverlay.openLinkedVideo = openDanmakuLinkedVideo
        view.setActionMenu(actionMenu, openURL: context.environment.openURL)
        view.startPlaybackEndObservation(playbackEnd)
        view.attachPlayer(player)
        view.setPlaybackPreparationBlocked(blocksNativePlaybackInteraction)
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.setResumeNotice(
            resumeNotice,
            restartFromBeginning: restartFromBeginning
        )
        view.setPreviewEndedNotice(previewEndedNotice)
        view.requestInitialKeyboardFocus(for: focusIdentity)
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
        nsView: NativePlayerHostView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    func updateNSView(_ view: NativePlayerHostView, context: Context) {
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

    /// 在 SwiftUI 销毁宿主时先撤销弹幕 surface，再断开 AVPlayer，避免旧 host 继续呈现。
    static func dismantleNSView(
        _ view: NativePlayerHostView,
        coordinator: ()
    ) {
        view.setResumeNotice(nil, restartFromBeginning: {})
        view.setPreviewEndedNotice(nil)
        view.stopPlaybackEndObservation()
        view.danmakuOverlay.detachSurface()
        view.danmakuOverlay.bind(to: nil)
        view.stopObservingFocusLoss()
        view.stopObservingPlayerItemChanges()
        view.stopKeyboardMonitoring()
        view.cancelMomentaryPlaybackRate()
        view.player = nil
    }
}
