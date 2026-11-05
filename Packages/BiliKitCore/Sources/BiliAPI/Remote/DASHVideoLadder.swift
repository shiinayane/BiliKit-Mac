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

/// 一次 DASH 播放的 SDR 视频阶梯：主阶梯只用一种编码，另附起播失败时回退用的 AVC 阶梯。
///
/// 规则按清晰度 ID 比较：HEVC 覆盖 AVC 的全部 SDR 档位时主阶梯用 HEVC（HEVC 独有的档位如 8K 一并
/// 加入），回退阶梯是 AVC；否则主阶梯用 AVC，没有回退。不混编码：同一 master 里 AVC 与 HEVC 并存时，
/// AVPlayer 的 ABR 会在两种编码之间切换。AV1 不用。见 ARCHITECTURE 的 DASH→HLS bridge 一节与“不采用”。
struct DASHVideoLadder: Sendable, Equatable {
    /// HDR 真彩（125）与杜比视界（126）的清晰度 ID。
    ///
    /// master 不写 `VIDEO-RANGE`，这两档混进 SDR 阶梯会被当成 SDR 选中、颜色错误，所以映射时排除。
    static let hdrQualityIDs: Set<Int> = [125, 126]

    let primary: [MediaRepresentation]
    let fallback: [MediaRepresentation]

    /// 单条 representation 映射失败（URL 不合规、缺尺寸等）只丢这一条，与播放桥丢弃读取失败的档位
    /// 一致；两种编码都没有可用的档位时，候选里有映射失败的报 `invalidMediaData`，否则报
    /// `noSupportedVideo`。
    init(_ payloads: [DASHRepresentationPayload]) throws {
        var avc: [MediaRepresentation] = []
        var hevc: [MediaRepresentation] = []
        var mappingFailed = false
        for payload in payloads where !Self.hdrQualityIDs.contains(payload.id) {
            guard let codec = payload.videoCodec else { continue }
            guard let representation = try? payload.model(kind: .video) else {
                mappingFailed = true
                continue
            }
            switch codec {
            case .avc: avc.append(representation)
            case .hevc: hevc.append(representation)
            }
        }
        if !hevc.isEmpty, Set(hevc.map(\.id)).isSuperset(of: avc.map(\.id)) {
            primary = hevc
            fallback = avc
        } else if !avc.isEmpty {
            primary = avc
            fallback = []
        } else {
            throw mappingFailed ? BiliAPIError.invalidMediaData : BiliAPIError.noSupportedVideo
        }
    }
}
