import AVFoundation
import Foundation
import Testing

@testable import BiliKit

/// seek 发起即在途、落地后不再在途且只记一次落地（四个入口都一样）；AVFoundation 永不回调的 seek（失败的
/// item、非有限时间）不会在换 item 后残留为在途。
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SeekTrackingPlayerTests {
    @Test
    func everyEntryLandsExactlyOnce() async throws {
        let fixture = try SilentAudioFixture(seconds: 8)
        defer { fixture.remove() }
        let player = SeekTrackingPlayer()
        player.replaceCurrentItem(with: AVPlayerItem(url: fixture.mediaURL))

        issueSeek(player, to: CMTime(seconds: 1, preferredTimescale: 600))
        #expect(await waitUntil(timeout: .seconds(10)) { !player.seekActivity.hasPendingSeek })
        #expect(player.seekActivity.landedSeekCount == 1)

        issueSeek(player, to: CMTime(seconds: 2, preferredTimescale: 600), tolerance: .zero)
        #expect(await waitUntil(timeout: .seconds(10)) { !player.seekActivity.hasPendingSeek })
        #expect(player.seekActivity.landedSeekCount == 2)

        let landedWithTolerance = await withCheckedContinuation { continuation in
            player.seek(
                to: CMTime(seconds: 3, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { continuation.resume(returning: $0) }
        }
        let landedByDefault = await withCheckedContinuation { continuation in
            player.seek(to: CMTime(seconds: 4, preferredTimescale: 600)) {
                continuation.resume(returning: $0)
            }
        }
        #expect(landedWithTolerance && landedByDefault)
        #expect(!player.seekActivity.hasPendingSeek)
        #expect(player.seekActivity.landedSeekCount == 4)
    }

    @Test
    func nonFiniteSeekIsNeverPending() async throws {
        let fixture = try SilentAudioFixture(seconds: 8)
        defer { fixture.remove() }
        let item = AVPlayerItem(url: fixture.mediaURL)
        let player = SeekTrackingPlayer(playerItem: item)
        #expect(await waitUntil(timeout: .seconds(10)) { item.status == .readyToPlay })

        for time in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity] {
            issueSeek(player, to: time)
            #expect(!player.seekActivity.hasPendingSeek)
        }
        #expect(player.seekActivity.landedSeekCount == 0)
    }

    @Test
    func seekOnFailedItemDoesNotOutliveTheItem() async throws {
        let fixture = try SilentAudioFixture(seconds: 8)
        defer { fixture.remove() }
        // 同目录下不存在的文件：item 加载失败。
        let failed = AVPlayerItem(url: fixture.directory.appendingPathComponent("missing.caf"))
        let player = SeekTrackingPlayer(playerItem: failed)
        #expect(await waitUntil(timeout: .seconds(10)) { failed.status == .failed })

        // 失败的 item 上的 seek 永不回调，换掉 item 之前一直在途。
        issueSeek(player, to: CMTime(seconds: 1, preferredTimescale: 600))
        #expect(player.seekActivity.hasPendingSeek)

        let next = AVPlayerItem(url: fixture.mediaURL)
        player.replaceCurrentItem(with: next)
        #expect(!player.seekActivity.hasPendingSeek)
        #expect(await waitUntil(timeout: .seconds(10)) { next.status == .readyToPlay })
        issueSeek(player, to: CMTime(seconds: 1, preferredTimescale: 600))
        #expect(await waitUntil(timeout: .seconds(10)) { !player.seekActivity.hasPendingSeek })
        #expect(player.seekActivity.landedSeekCount == 1)
    }
}

/// 走不带回调的同步入口（AVKit 用的路径）；在 async 上下文里直接写 `seek(to:)` 会选中 async 重载。
@MainActor
private func issueSeek(_ player: AVPlayer, to time: CMTime, tolerance: CMTime? = nil) {
    if let tolerance {
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
    } else {
        player.seek(to: time)
    }
}
