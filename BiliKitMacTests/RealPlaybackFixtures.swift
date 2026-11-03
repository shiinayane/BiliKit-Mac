import AVFoundation
import BiliDanmaku
import CoreMedia
import Foundation
import QuartzCore
import Testing

/// renderer 挂在滚动、顶部、底部三个锚点层下的全部弹幕 layer，按锚点顺序、各自按挂上的先后。
///
/// `rootLayer` 的前三个子层是锚点层，之后是互动弹幕卡片容器，卡片不算弹幕 layer。
@MainActor
func danmakuLayers(of renderer: CoreAnimationDanmakuRenderer) -> [CALayer] {
    (renderer.rootLayer.sublayers ?? []).prefix(3).flatMap { $0.sublayers ?? [] }
}

/// `timebase` 在宿主时刻 `host`（与 `CACurrentMediaTime()` 同为 mach 时间的秒数）的媒体时间。
///
/// 与 `CALayer.convertTime(host, from: nil)` 按同一个宿主时刻比较，结果与读取的先后和间隔无关；分两次各取
/// 此刻时，两次读取之间的抢占会按速率变成偏差。
func mediaTime(of timebase: CMTimebase, atHost host: Double) -> Double {
    CMSyncConvertTime(
        CMTime(seconds: host, preferredTimescale: 1_000_000_000),
        from: CMClockGetHostTimeClock(),
        to: timebase
    ).seconds
}

/// 独占临时目录里的一段静音 PCM 音频：有音轨，播放器按音频时钟驱动 item 的 timebase。
///
/// 拥有这个目录；测试结束时调用 `remove()` 删除整个目录（同目录下测试自己放的文件一并删除）。
struct SilentAudioFixture {
    let directory: URL
    let mediaURL: URL

    init(seconds: Double) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BiliKitMacTests.audio.\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            mediaURL = try Self.writeSilence(seconds: seconds, in: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        self.directory = directory
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func writeSilence(seconds: Double, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("silence.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        try file.write(from: buffer)
        return url
    }
}
