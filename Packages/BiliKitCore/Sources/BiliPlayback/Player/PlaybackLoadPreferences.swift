import Foundation

/// 每次新 load 读一次的播放偏好快照，由 App 层组装后经 `AVPlayerEngine` 的 provider 交给引擎。
///
/// 设置变化不触碰当前播放项，下一次 load 才生效。`allowsHDRVideo` 已经合并了“HDR 视频”开关与 App
/// 能看到的环境条件（窗口所在屏幕、低电量、网络），引擎再加上 `AVPlayer.eligibleForHDRPlayback`。
public struct PlaybackLoadPreferences: Sendable, Equatable {
    public let sourcePreference: PlaybackSourcePreference
    public let allowsHDRVideo: Bool

    public init(sourcePreference: PlaybackSourcePreference, allowsHDRVideo: Bool) {
        self.sourcePreference = sourcePreference
        self.allowsHDRVideo = allowsHDRVideo
    }
}
