@preconcurrency import AVFoundation
import BiliModels
import Foundation

/// 一次 load 交给 `DASHToHLSBridge` 的输入，由 `AVPlayerEngine.performLoad` 组装。
///
/// 主阶梯起播失败、换用回退阶梯时只换 `videos` 并去掉 HDR 档（回退阶梯是 AVC，HDR 档只配 HEVC），
/// 音轨、字幕来源、请求头与起播位置不变。
struct BridgePreparation: Sendable {
    let progressiveSource: ProgressivePlaybackSource?
    let videos: [MediaRepresentation]
    /// 已按设置与环境放行的 HDR 候选档；不允许 HDR 时为空。
    let hdrVideos: [MediaRepresentation]
    let audioTracks: [SelectedPlaybackAudioTrack]
    let headers: [String: String]
    let subtitleSource: NativeSubtitleSource?
    let startPositionSeconds: Double?

    func replacingVideos(_ videos: [MediaRepresentation]) -> BridgePreparation {
        BridgePreparation(
            progressiveSource: progressiveSource,
            videos: videos,
            hdrVideos: [],
            audioTracks: audioTracks,
            headers: headers,
            subtitleSource: subtitleSource,
            startPositionSeconds: startPositionSeconds
        )
    }

    /// 带了原声无损版本时让 AVPlayer 在带宽足够时选无损音频组。
    ///
    /// 不设这个偏好时 AVPlayer 从不自动选 FLAC（实测，见 ARCHITECTURE）。无损组读取失败被丢掉时这个偏好没有可作用的对象，不影响播放。
    var variantPreferences: AVVariantPreferences {
        audioTracks.contains { selected in
            selected.track.losslessRepresentation.map(selected.additionalRepresentations.contains)
                ?? false
        } ? .scalabilityToLosslessAudio : []
    }

    func prepare(using bridge: DASHToHLSBridge) async throws -> PreparedPlaybackAsset {
        if let progressiveSource {
            try await bridge.prepare(progressive: progressiveSource, headers: headers)
        } else {
            try await bridge.prepare(
                videos: videos,
                hdrVideos: hdrVideos,
                audioTracks: audioTracks,
                headers: headers,
                subtitleSource: subtitleSource,
                startPositionSeconds: startPositionSeconds
            )
        }
    }
}
