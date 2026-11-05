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

    /// 并行读取各音轨的 SIDX 与音频格式（原声连同它的附加版本），按输入顺序返回；机器配音音轨失败时只丢弃
    /// 该轨，原声失败让整次播放失败，取消原样传播。
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
                        async let additionalVersions = loadAdditionalAudioVersions(
                            selectedTrack.additionalRepresentations,
                            headers: headers
                        )
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
                                format: format,
                                additionalVersions: try await additionalVersions
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

    /// 并行读取原声附加版本的 SIDX 与音频格式，按输入顺序返回读取成功的版本；取消原样传播。
    ///
    /// 附加版本只是更多选择：任一版本读取失败、缺完整长度、没有可播分段或读不出音频格式就只丢这一个
    /// 版本（它的音频组），
    /// 原声与其余版本照常。音频格式在这里是必需的：杜比音频要靠 `CHANNELS` 让 AVPlayer 按输出声道数
    /// 选择，写不出来时宁可不提供这一组。
    private func loadAdditionalAudioVersions(
        _ representations: [MediaRepresentation],
        headers: [String: String]
    ) async throws -> [LoadedAudioVersion] {
        try await withThrowingTaskGroup(of: (Int, LoadedAudioVersion?).self) { group in
            for (offset, representation) in representations.enumerated() {
                group.addTask {
                    do {
                        let index = try await indexLoader.load(
                            for: representation,
                            headers: headers
                        )
                        guard let length = index.completeMediaLength,
                            index.index.hasPlayableSegments,
                            let format = try await optionalAudioFormat(
                                for: representation,
                                sourceURL: index.sourceURL,
                                headers: headers
                            )
                        else {
                            return (offset, nil)
                        }
                        return (
                            offset,
                            LoadedAudioVersion(
                                representation: representation,
                                index: index,
                                completeMediaLength: length,
                                format: format
                            )
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (offset, nil)
                    }
                }
            }
            var loaded: [(Int, LoadedAudioVersion?)] = []
            for try await result in group {
                loaded.append(result)
            }
            return loaded.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }
    }
}

/// 一条读取成功的音频 rendition：所选音轨、SIDX、音频格式（读取失败时为 nil，不影响播放），以及原声
/// 读取成功的附加版本（时间轴尚未核对，由 `DASHToHLSBridge.prepare` 对照原声起点过滤）。
struct LoadedAudioRendition: Sendable {
    let selectedTrack: SelectedPlaybackAudioTrack
    let index: LoadedSegmentIndex
    let format: AudioFormatMetadata?
    let additionalVersions: [LoadedAudioVersion]
}

/// 原声的一个附加版本：representation、SIDX、完整长度与音频格式；每个版本成为一个音频组。
struct LoadedAudioVersion: Sendable {
    let representation: MediaRepresentation
    let index: LoadedSegmentIndex
    let completeMediaLength: Int64
    let format: AudioFormatMetadata
}
