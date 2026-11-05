import Foundation
import Testing

/// 杜比视界配置记录（`dvvC`）里的 profile、level 与基础层兼容 ID。
struct DolbyVisionFixture: Sendable {
    let profile: Int
    let level: Int
    let compatibilityID: Int
}

/// 合成只有一条 HEVC 视频 track 的 fMP4 init：`ftyp` 与 `moov/trak/mdia/minf/stbl/stsd/<sampleEntry>`，
/// sample entry 下按参数带 nclx `colr`（`transfer` 为传递函数编号）与 `dvvC`。
func makeHEVCInitialization(
    sampleEntry: String = "hvc1",
    transfer: UInt16? = 16,
    dolbyVision: DolbyVisionFixture? = nil
) -> Data {
    var entryChildren = Data()
    if let transfer {
        var color = Data("nclx".utf8)
        color += bigEndianBytes(UInt16(9)) + bigEndianBytes(transfer) + bigEndianBytes(UInt16(9))
        color.append(0)
        entryChildren += isoBox("colr", color)
    }
    if let dolbyVision {
        var configuration = Data([1, 0])
        let bits = UInt16(dolbyVision.profile << 9 | dolbyVision.level << 3 | 0b101)
        configuration += bigEndianBytes(bits)
        configuration.append(UInt8(dolbyVision.compatibilityID << 4))
        configuration += Data(count: 19)
        entryChildren += isoBox("dvvC", configuration)
    }
    let entry = isoBox(sampleEntry, Data(count: 78) + entryChildren)
    let description = isoBox("stsd", Data(count: 4) + bigEndianBytes(UInt32(1)) + entry)
    let track = isoBox(
        "trak",
        isoBox("mdia", isoBox("minf", isoBox("stbl", description)))
    )
    return isoBox("ftyp", Data("iso6".utf8) + Data(count: 4)) + isoBox("moov", track)
}

/// 把 fixture 媒体的 init（首个 `sidx` 之前的字节）换成 `initialization`，SIDX 与分段原样保留。
func replacingInitialization(in media: Data, with initialization: Data) throws -> Data {
    let sidx = try #require(firstTopLevelBox(named: "sidx", in: media))
    return initialization + media.suffix(from: sidx.offset)
}

func isoBox(_ type: String, _ payload: Data) -> Data {
    bigEndianBytes(UInt32(8 + payload.count)) + Data(type.utf8) + payload
}

private func bigEndianBytes<Value: FixedWidthInteger>(_ value: Value) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
}

/// 合成只有一条音频 track 的 fMP4 init：AudioSampleEntry（version 0）固定字段写声道 2、位深 16、
/// 采样率 48000，其后接 `children`（如 `dec3`、`dfLa`）。
func makeAudioInitialization(sampleEntry: String, children: Data) -> Data {
    var fields = Data(count: 6) + bigEndianBytes(UInt16(1))
    fields += Data(count: 8)
    fields += bigEndianBytes(UInt16(2)) + bigEndianBytes(UInt16(16))
    fields += Data(count: 4)
    fields += bigEndianBytes(UInt32(48_000) << 16)
    let entry = isoBox(sampleEntry, fields + children)
    let description = isoBox("stsd", Data(count: 4) + bigEndianBytes(UInt32(1)) + entry)
    let track = isoBox(
        "trak",
        isoBox("mdia", isoBox("minf", isoBox("stbl", description)))
    )
    return isoBox("ftyp", Data("iso6".utf8) + Data(count: 4)) + isoBox("moov", track)
}

/// E-AC-3 的 `dec3`：data_rate 1024、一个独立子流（bsid 16），声道布局由 `acmod`、`lfe` 与依赖子流数给出。
func eac3Configuration(acmod: UInt8, lfe: Bool, dependentSubstreams: UInt8 = 0) -> Data {
    isoBox(
        "dec3",
        Data([0x20, 0x00, 16 << 1, (acmod << 1) | (lfe ? 1 : 0), dependentSubstreams << 1])
    )
}

/// FLAC 的 `dfLa`：FullBox 头后只有一个（最后一个）STREAMINFO 块。
func flacConfiguration(sampleRate: UInt64, channels: UInt64, bitDepth: UInt64) -> Data {
    var streamInfo = Data(count: 10)
    streamInfo += bigEndianBytes(
        sampleRate << 44 | (channels - 1) << 41 | (bitDepth - 1) << 36 | 4_800_000
    )
    streamInfo += Data(count: 16)
    return isoBox("dfLa", Data(count: 4) + Data([0x80, 0, 0, 34]) + streamInfo)
}

/// 把 SIDX 的起始呈现时间加一秒，让这份媒体的时间轴起点与同一稿件的其他档不同。
func shiftingTimelineOrigin(of data: Data) throws -> Data {
    var result = data
    let sidx = try #require(firstTopLevelBox(named: "sidx", in: result))
    let timescale = Int(readUInt32(in: result, at: sidx.offset + 16))
    let valueOffset = sidx.offset + 20
    switch result[sidx.offset + 8] {
    case 0:
        let shifted = readUInt32(in: result, at: valueOffset) + UInt32(timescale)
        result.replaceSubrange(
            valueOffset..<(valueOffset + 4),
            with: withUnsafeBytes(of: shifted.bigEndian) { Data($0) }
        )
    default:
        let high = UInt64(readUInt32(in: result, at: valueOffset)) << 32
        let shifted =
            high + UInt64(readUInt32(in: result, at: valueOffset + 4)) + UInt64(timescale)
        result.replaceSubrange(
            valueOffset..<(valueOffset + 8),
            with: withUnsafeBytes(of: shifted.bigEndian) { Data($0) }
        )
    }
    return result
}
