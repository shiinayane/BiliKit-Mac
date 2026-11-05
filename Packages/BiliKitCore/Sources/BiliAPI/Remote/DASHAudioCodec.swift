import BiliModels
import Foundation

/// DASH 音频 representation 的编码；只列出播放桥能交给 AVPlayer 的三种，其他编码为 nil。
///
/// 音频编码只在这里分类：`dash.audio` 里只用 AAC，`dash.dolby` 只用 E-AC-3，`dash.flac` 只用 FLAC。
enum DASHAudioCodec: Sendable, Equatable {
    case aac
    case eac3
    case flac
}

extension DASHRepresentationPayload {
    var audioCodec: DASHAudioCodec? {
        guard mimeType == "audio/mp4" else { return nil }
        let codecs = codecs.lowercased()
        if codecs.hasPrefix("mp4a") {
            return .aac
        }
        if codecs == "ec-3" {
            return .eac3
        }
        if codecs == "flac" {
            return .flac
        }
        return nil
    }
}

extension DASHPayload {
    /// 原声的杜比音频版本：`dash.dolby.audio` 里第一条 E-AC-3 且能通过映射的 representation。
    var originalDolbyAudio: MediaRepresentation? {
        Self.firstMappable(dolbyAudio, codec: .eac3)
    }

    /// 原声的无损版本：`dash.flac.audio` 是 FLAC 且能通过映射时的 representation。
    var originalLosslessAudio: MediaRepresentation? {
        Self.firstMappable(losslessAudio.map { [$0] } ?? [], codec: .flac)
    }

    /// 附加版本不合规（编码不对、来源不过 `BiliMediaCDNURLPolicy`、区间不合法）时只是没有这个版本，
    /// 原声的 AAC 照常播放，所以映射失败不向上抛。
    private static func firstMappable(
        _ candidates: [DASHRepresentationPayload],
        codec: DASHAudioCodec
    ) -> MediaRepresentation? {
        candidates.lazy
            .filter { $0.audioCodec == codec }
            .compactMap { try? $0.model(kind: .audio) }
            .first
    }
}
