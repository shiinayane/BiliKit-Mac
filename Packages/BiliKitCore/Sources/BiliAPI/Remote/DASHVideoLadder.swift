import BiliModels
import Foundation

/// DASH 视频 representation 的编码；只列出播放桥能交给 AVPlayer 的两种，AV1 等其他编码为 nil。
enum DASHVideoCodec: Sendable, Equatable {
    case avc
    case hevc
}

extension DASHRepresentationPayload {
    var videoCodec: DASHVideoCodec? {
        guard mimeType == "video/mp4" else { return nil }
        let codecs = codecs.lowercased()
        if codecid == 7 || codecs.hasPrefix("avc1") {
            return .avc
        }
        if codecid == 12 || codecs.hasPrefix("hev1") || codecs.hasPrefix("hvc1") {
            return .hevc
        }
        return nil
    }
}

/// 一次 DASH 播放的视频阶梯：只用一种编码的 SDR 主阶梯、起播失败时回退用的 AVC 阶梯，以及 HDR 候选档。
///
/// 规则按清晰度 ID 比较：HEVC 覆盖 AVC 的全部 SDR 档位时主阶梯用 HEVC（HEVC 独有的档位如 8K 一并
/// 加入），回退阶梯是 AVC；否则主阶梯用 AVC，没有回退。不混编码：同一 master 里 AVC 与 HEVC 并存时，
/// AVPlayer 的 ABR 会在两种编码之间切换。AV1 不用。见 ARCHITECTURE 的 DASH→HLS bridge 一节与“不采用”。
struct DASHVideoLadder: Sendable, Equatable {
    /// 杜比视界（126）、HDR 真彩（125）与 HDR Vivid（129）的清晰度 ID，按优先顺序排列。
    ///
    /// 它们不进 SDR 阶梯：HDR 档必须带 `VIDEO-RANGE` 写进 master，否则会被当成 SDR 选中、颜色错误
    /// （PQ 不标时 item 直接失败，整条 HEVC 阶梯随之回退到 AVC）。129 还没有实测样本，作为最后的候选；
    /// 它的 init 读不出 HDR 时只丢这一档。
    static let hdrQualityIDs = [126, 125, 129]

    let primary: [MediaRepresentation]
    let fallback: [MediaRepresentation]
    /// 主阶梯是 HEVC 时的 HEVC HDR 档，杜比视界在前；主阶梯是 AVC 时为空。
    ///
    /// 是否真的加入、加入哪一档由 BiliPlayback 在加载时决定。
    let hdrCandidates: [MediaRepresentation]

    /// 单条 representation 映射失败（URL 不合规、缺尺寸等）只丢这一条，与播放桥丢弃读取失败的档位
    /// 一致；两种编码都没有可用的档位时，候选里有映射失败的报 `invalidMediaData`，否则报
    /// `noSupportedVideo`。
    init(_ payloads: [DASHRepresentationPayload]) throws {
        var avc: [MediaRepresentation] = []
        var hevc: [MediaRepresentation] = []
        var hevcHDR: [MediaRepresentation] = []
        var mappingFailed = false
        for payload in payloads {
            guard let codec = payload.videoCodec else { continue }
            let isHDR = Self.hdrQualityIDs.contains(payload.id)
            guard let representation = try? payload.model(kind: .video) else {
                // HDR 档映射失败只是少一个可选档，不影响 SDR 阶梯的错误判断。
                mappingFailed = mappingFailed || !isHDR
                continue
            }
            switch (codec, isHDR) {
            case (.avc, false): Self.appendFirst(representation, to: &avc)
            case (.hevc, false): Self.appendFirst(representation, to: &hevc)
            case (.hevc, true): Self.appendFirst(representation, to: &hevcHDR)
            case (.avc, true): continue
            }
        }
        if !hevc.isEmpty, Set(hevc.map(\.id)).isSuperset(of: avc.map(\.id)) {
            primary = hevc
            fallback = avc
            hdrCandidates = Self.hdrQualityIDs.flatMap { id in
                hevcHDR.filter { $0.id == id }
            }
        } else if !avc.isEmpty {
            primary = avc
            fallback = []
            hdrCandidates = []
        } else {
            throw mappingFailed ? BiliAPIError.invalidMediaData : BiliAPIError.noSupportedVideo
        }
    }

    /// 同一编码、同一清晰度只留第一条：bridge 要求视频档 ID 唯一，重复会让整次准备失败。
    private static func appendFirst(
        _ representation: MediaRepresentation,
        to list: inout [MediaRepresentation]
    ) {
        guard !list.contains(where: { $0.id == representation.id }) else { return }
        list.append(representation)
    }
}
