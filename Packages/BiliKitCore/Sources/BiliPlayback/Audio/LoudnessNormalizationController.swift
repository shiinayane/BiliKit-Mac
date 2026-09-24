@preconcurrency import AVFoundation
import BiliModels
import Foundation

/// 实验性响度均一化（仅 macOS 26）的 item 级 owner：安装 tap，并随系统音轨选择更新增益。
///
/// `clear` 让在途的音轨选择更新全部失效；元数据缺失、音轨无法唯一映射或查询失败时保持 unity。
@MainActor
final class LoudnessNormalizationController {
    private var tap: LoudnessProcessingTap?
    private weak var item: AVPlayerItem?
    private var audioTracks: [PlaybackAudioTrack] = []
    private var selectionObserver: (any NSObjectProtocol)?
    private var selectionTask: Task<Void, Never>?
    private var selectionOperationID: UUID?

    deinit {
        selectionTask?.cancel()
        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }
    }

    /// 在 item 交给 AVPlayer 前安装 tap；运行时、开关或元数据不满足时保持原样。
    func install(
        on item: AVPlayerItem,
        audioTracks: [SelectedPlaybackAudioTrack],
        enabled: Bool
    ) {
        guard
            LoudnessNormalizationRuntimePolicy.shouldInstall(
                enabled: enabled,
                hasMetadata: audioTracks.contains {
                    $0.track.loudnessMetadata != nil
                }
            ),
            let defaultTrack = audioTracks.first(where: { $0.track.isDefault }),
            let tap = LoudnessProcessingTap.make(
                initialGain: LoudnessNormalizationPolicy().linearGain(
                    for: defaultTrack.track.loudnessMetadata
                )
            )
        else { return }
        self.tap = tap
        self.item = item
        self.audioTracks = audioTracks.map(\.track)
        item.audioMix = tap.makeAudioMix()
    }

    /// item 就绪后开始跟随音轨选择，并按当前选择设定一次增益。
    func activate() async {
        guard let item, tap != nil else { return }
        selectionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.item === item else { return }
                self.selectionTask?.cancel()
                let operationID = UUID()
                self.selectionOperationID = operationID
                self.selectionTask = Task { @MainActor [weak self] in
                    await self?.updateGain(operationID: operationID)
                }
            }
        }
        let operationID = UUID()
        selectionOperationID = operationID
        await updateGain(operationID: operationID)
    }

    func clear() {
        selectionTask?.cancel()
        selectionTask = nil
        selectionOperationID = nil
        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }
        selectionObserver = nil
        audioTracks = []
        tap = nil
        item = nil
    }

    private func updateGain(operationID: UUID) async {
        guard let tap, let item,
            isCurrent(operationID, item: item, tap: tap)
        else { return }

        let group: AVMediaSelectionGroup?
        do {
            group = try await item.asset.loadMediaSelectionGroup(for: .audible)
        } catch {
            guard isCurrent(operationID, item: item, tap: tap) else { return }
            tap.setTargetGain(1)
            return
        }
        guard isCurrent(operationID, item: item, tap: tap) else { return }

        let metadata: PlaybackLoudnessMetadata?
        if let group,
            let option = item.currentMediaSelection.selectedMediaOption(in: group)
        {
            let matches = audioTracks.filter {
                Self.matches($0, option: option)
            }
            metadata = matches.count == 1 ? matches[0].loudnessMetadata : nil
        } else {
            metadata = nil
        }
        tap.setTargetGain(LoudnessNormalizationPolicy().linearGain(for: metadata))
    }

    private func isCurrent(
        _ operationID: UUID,
        item: AVPlayerItem,
        tap: LoudnessProcessingTap
    ) -> Bool {
        !Task.isCancelled
            && selectionOperationID == operationID
            && self.item === item
            && self.tap === tap
    }

    private static func matches(
        _ track: PlaybackAudioTrack,
        option: AVMediaSelectionOption
    ) -> Bool {
        let expectedLanguage = (track.languageTag ?? "und")
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let actualLanguage = (option.locale?.identifier ?? "und")
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let characteristic = AVMediaCharacteristic(
            rawValue:
                track.role == .original
                ? "public.original-content" : "public.machine-generated"
        )
        return option.displayName == track.displayName
            && actualLanguage == expectedLanguage
            && option.hasMediaCharacteristic(characteristic)
    }
}
