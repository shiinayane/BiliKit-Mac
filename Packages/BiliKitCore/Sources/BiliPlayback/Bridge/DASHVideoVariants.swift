import BiliModels
import Foundation

extension DASHToHLSBridge {
    /// 按顺序读取 HDR 候选档，返回第一个 SIDX（有可播分段）、完整长度与 init 动态范围都成功的档；
    /// 都不成功时返回 nil。
    ///
    /// HDR 档是附加内容：任一步失败只丢这一档、再试下一个候选，不让播放失败；取消原样传播。缺帧率的
    /// 候选直接跳过：AVPlayer 按 `FRAME-RATE` 判断设备能否解码这一档，HDR 档不写它时选档没有依据。
    func loadHDRVariant(
        _ candidates: [MediaRepresentation],
        headers: [String: String]
    ) async throws -> LoadedHDRVariant? {
        for candidate in candidates where candidate.videoAttributes?.frameRate != nil {
            do {
                let index = try await indexLoader.load(for: candidate, headers: headers)
                guard let completeMediaLength = index.completeMediaLength,
                    index.index.hasPlayableSegments
                else { continue }
                let metadata = try await initializationLoader.load(
                    for: candidate,
                    sourceURL: index.sourceURL,
                    headers: headers,
                    parse: { try VideoDynamicRangeParser().parse($0) }
                )
                return LoadedHDRVariant(
                    video: LoadedVideoVariant(
                        representation: candidate,
                        index: index,
                        completeMediaLength: completeMediaLength
                    ),
                    metadata: metadata
                )
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
            }
        }
        return nil
    }

    /// 并行读取各档视频 SIDX；某一档失败（全部候选失败或缺少完整长度）时丢弃该档，只要还有一档
    /// 可用就继续播放。
    ///
    /// 与 AI 配音一致，附加内容失败不拖垮播放。取消原样传播，不当成某一档失败；全部失败时抛出排在
    /// 最前的那一档的错误。
    func loadVideoVariants(
        _ videos: [MediaRepresentation],
        headers: [String: String]
    ) async throws -> [LoadedVideoVariant] {
        try await withThrowingTaskGroup(
            of: (Int, Result<LoadedVideoVariant, any Error>).self
        ) { group in
            for (offset, video) in videos.enumerated() {
                group.addTask {
                    do {
                        let index = try await indexLoader.load(
                            for: video,
                            headers: headers
                        )
                        guard let completeMediaLength = index.completeMediaLength else {
                            throw DASHToHLSBridgeError.missingCompleteMediaLength(
                                representationID: video.id
                            )
                        }
                        return (
                            offset,
                            .success(
                                LoadedVideoVariant(
                                    representation: video,
                                    index: index,
                                    completeMediaLength: completeMediaLength
                                )
                            )
                        )
                    } catch {
                        if Task.isCancelled || error is CancellationError {
                            throw CancellationError()
                        }
                        return (offset, .failure(error))
                    }
                }
            }

            var ordered = [Result<LoadedVideoVariant, any Error>?](
                repeating: nil,
                count: videos.count
            )
            for try await (offset, result) in group {
                ordered[offset] = result
            }
            let loaded = ordered.compactMap { try? $0?.get() }
            if loaded.isEmpty, case .failure(let error)? = ordered.first {
                throw error
            }
            return loaded
        }
    }
}

/// 一档读取成功的 HDR 视频与它的 init 给出的动态范围。
struct LoadedHDRVariant: Sendable {
    let video: LoadedVideoVariant
    let metadata: VideoDynamicRangeMetadata
}

/// 一档读取成功的视频：representation、SIDX 与 SIDX 响应给出的完整媒体长度（loopback 媒体资源需要它）。
struct LoadedVideoVariant: Sendable {
    let representation: MediaRepresentation
    let index: LoadedSegmentIndex
    let completeMediaLength: Int64
}
