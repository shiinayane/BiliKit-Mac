import BiliModels
import BiliNetworking
import Foundation

extension DASHToHLSBridge {
    /// 音频格式只是 master 里的可选属性：读取或解析失败时返回 nil，不输出相应属性，播放照常；
    /// 取消原样传播。
    private func optionalAudioFormat(
        for audio: MediaRepresentation,
        sourceURL: URL,
        headers: [String: String]
    ) async throws -> AudioFormatMetadata? {
        do {
            return try await initializationLoader.load(
                for: audio,
                sourceURL: sourceURL,
                headers: headers,
                parse: { try AudioFormatMetadataParser().parse($0) }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// 并行读取各音轨的 SIDX 与音频格式，按输入顺序返回；机器配音音轨失败时只丢弃该轨，
    /// 原声失败让整次播放失败，取消原样传播。
    func loadAudioRenditions(
        _ audioTracks: [SelectedPlaybackAudioTrack],
        headers: [String: String]
    ) async throws -> [LoadedAudioRendition] {
        try await withThrowingTaskGroup(
            of: (Int, LoadedAudioRendition?).self
        ) { group in
            for (offset, selectedTrack) in audioTracks.enumerated() {
                group.addTask {
                    do {
                        let audio = selectedTrack.representation
                        let index = try await indexLoader.load(
                            for: audio,
                            headers: headers
                        )
                        guard index.completeMediaLength != nil else {
                            if selectedTrack.track.role == .machineGenerated {
                                return (offset, nil)
                            }
                            throw
                                DASHToHLSBridgeError
                                .missingCompleteMediaLength(
                                    representationID: audio.id
                                )
                        }
                        let format = try await optionalAudioFormat(
                            for: audio,
                            sourceURL: index.sourceURL,
                            headers: headers
                        )
                        return (
                            offset,
                            LoadedAudioRendition(
                                selectedTrack: selectedTrack,
                                index: index,
                                format: format
                            )
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch  where selectedTrack.track.role == .machineGenerated {
                        return (offset, nil)
                    } catch {
                        throw error
                    }
                }
            }
            var loaded: [(Int, LoadedAudioRendition?)] = []
            loaded.reserveCapacity(audioTracks.count)
            for try await result in group {
                loaded.append(result)
            }
            return loaded.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }
    }
}

/// 一条读取成功的音频 rendition：所选音轨、SIDX 与音频格式（读取失败时为 nil，不影响播放）。
struct LoadedAudioRendition: Sendable {
    let selectedTrack: SelectedPlaybackAudioTrack
    let index: LoadedSegmentIndex
    let format: AudioFormatMetadata?
}
