import BiliModels
import Foundation

/// 解析后的 SIDX：时间基、起始呈现时间与按顺序排列的分段引用（绝对字节范围）。
public struct SegmentIndex: Sendable, Equatable {
    public let referenceID: UInt32
    public let timescale: UInt32
    public let earliestPresentationTime: UInt64
    public let firstOffset: UInt64
    public let references: [SegmentReference]

    public init(
        referenceID: UInt32,
        timescale: UInt32,
        earliestPresentationTime: UInt64,
        firstOffset: UInt64,
        references: [SegmentReference]
    ) {
        self.referenceID = referenceID
        self.timescale = timescale
        self.earliestPresentationTime = earliestPresentationTime
        self.firstOffset = firstOffset
        self.references = references
    }

    /// 至少一段，且每个 reference 都从 type-1 SAP 开始、`SAP_delta_time` 为 0，即每段第一个样本就是闭合
    /// GOP 的可独立解码帧。
    ///
    /// 独立分段的唯一判定：media 与 master playlist 的 `EXT-X-INDEPENDENT-SEGMENTS`、I-frame rendition 都只认
    /// 它。type 2、3 是开放 GOP 等情形，段首之后的帧可能引用上一段，不能声明为独立。空索引没有可声明独立的
    /// 分段，判为否。
    var hasIndependentSegments: Bool {
        !references.isEmpty
            && references.allSatisfy { reference in
                reference.startsWithSAP
                    && reference.sapType == 1
                    && reference.sapDeltaTime == 0
            }
    }

    /// 至少一段且每段时长大于 0：media playlist 与 master 的码率计算只接受这样的索引。
    ///
    /// SIDX 解析本身接受空索引与零时长分段（它们会在生成 playlist 时报错、让整次播放失败）；可选的
    /// HDR 档与原声附加版本在读取时用这一条判断，不合格只丢那一档或那一组。
    var hasPlayableSegments: Bool {
        !references.isEmpty && references.allSatisfy { $0.duration > 0 }
    }
}

/// 一个分段的绝对字节范围、以 `timescale` 计的时长与 SAP 信息；独立分段与 I-frame 判定依赖 SAP
/// 字段。
public struct SegmentReference: Sendable, Equatable {
    public let byteRange: MediaByteRange
    public let duration: UInt32
    public let startsWithSAP: Bool
    public let sapType: UInt8
    public let sapDeltaTime: UInt32

    public init(
        byteRange: MediaByteRange,
        duration: UInt32,
        startsWithSAP: Bool,
        sapType: UInt8,
        sapDeltaTime: UInt32
    ) {
        self.byteRange = byteRange
        self.duration = duration
        self.startsWithSAP = startsWithSAP
        self.sapType = sapType
        self.sapDeltaTime = sapDeltaTime
    }
}

/// SIDX 不合规或超出支持范围；读取时这个候选按失败处理。
public enum SIDXParserError: Error, Sendable, Equatable {
    case truncated
    case invalidBoxSize(declared: UInt32, actual: Int)
    case invalidBoxType(UInt32)
    case unsupportedVersion(UInt8)
    case invalidTimescale
    case invalidReferenceSize(index: Int)
    case unsupportedIndirectReference(index: Int)
    case integerOverflow
    case unexpectedTrailingBytes(Int)
    case indexTooLarge(byteCount: UInt64)
}

/// 解析独立的 ISO BMFF `sidx` box，并把相对引用换算为经过溢出检查的绝对字节范围。
///
/// 当前只接受直接媒体引用、v0/v1 与无尾随字节的完整 box；不支持的结构会失败关闭。
public struct SIDXParser: Sendable {
    /// `index_range` 与 SIDX 正文的上限。
    ///
    /// reference_count 是 16 位，合法 v1 box 最大约 768 KiB；超过 1 MiB 的区间不可能是合法 SIDX，
    /// 在发起读取前就拒绝。
    public static let maximumBoxByteCount = 1_024 * 1_024

    public init() {}

    public func parse(
        _ data: Data,
        boxStartOffset: UInt64 = 0
    ) throws -> SegmentIndex {
        guard data.count <= Self.maximumBoxByteCount else {
            throw SIDXParserError.indexTooLarge(byteCount: UInt64(data.count))
        }
        var reader = BigEndianReader(data: data)
        let declaredSize = try reader.readUInt32()
        guard data.count <= UInt32.max,
            declaredSize == UInt32(data.count)
        else {
            throw SIDXParserError.invalidBoxSize(
                declared: declaredSize,
                actual: data.count
            )
        }

        let boxType = try reader.readUInt32()
        guard boxType == 0x7369_6478 else {
            throw SIDXParserError.invalidBoxType(boxType)
        }

        let version = try reader.readUInt8()
        guard version == 0 || version == 1 else {
            throw SIDXParserError.unsupportedVersion(version)
        }
        try reader.skip(3)

        let referenceID = try reader.readUInt32()
        let timescale = try reader.readUInt32()
        guard timescale > 0 else {
            throw SIDXParserError.invalidTimescale
        }

        let earliestPresentationTime: UInt64
        let firstOffset: UInt64
        if version == 0 {
            earliestPresentationTime = UInt64(try reader.readUInt32())
            firstOffset = UInt64(try reader.readUInt32())
        } else {
            earliestPresentationTime = try reader.readUInt64()
            firstOffset = try reader.readUInt64()
        }

        try reader.skip(2)
        let referenceCount = Int(try reader.readUInt16())

        let boxEndOffset = try adding(
            boxStartOffset,
            UInt64(declaredSize)
        )
        var nextMediaOffset = try adding(boxEndOffset, firstOffset)
        var references: [SegmentReference] = []
        references.reserveCapacity(referenceCount)

        for index in 0..<referenceCount {
            let referenceTypeAndSize = try reader.readUInt32()
            let isIndirectReference = referenceTypeAndSize & 0x8000_0000 != 0
            guard !isIndirectReference else {
                throw SIDXParserError.unsupportedIndirectReference(index: index)
            }

            let referencedSize = UInt64(referenceTypeAndSize & 0x7fff_ffff)
            guard referencedSize > 0 else {
                throw SIDXParserError.invalidReferenceSize(index: index)
            }

            let duration = try reader.readUInt32()
            let sap = try reader.readUInt32()
            let endExclusive = try adding(nextMediaOffset, referencedSize)
            guard nextMediaOffset <= UInt64(Int64.max),
                endExclusive - 1 <= UInt64(Int64.max)
            else {
                throw SIDXParserError.integerOverflow
            }

            let byteRange: MediaByteRange
            do {
                byteRange = try MediaByteRange(
                    start: Int64(nextMediaOffset),
                    endInclusive: Int64(endExclusive - 1)
                )
            } catch {
                throw SIDXParserError.integerOverflow
            }

            references.append(
                SegmentReference(
                    byteRange: byteRange,
                    duration: duration,
                    startsWithSAP: sap & 0x8000_0000 != 0,
                    sapType: UInt8((sap >> 28) & 0x7),
                    sapDeltaTime: sap & 0x0fff_ffff
                )
            )
            nextMediaOffset = endExclusive
        }

        guard reader.remainingByteCount == 0 else {
            throw SIDXParserError.unexpectedTrailingBytes(reader.remainingByteCount)
        }

        return SegmentIndex(
            referenceID: referenceID,
            timescale: timescale,
            earliestPresentationTime: earliestPresentationTime,
            firstOffset: firstOffset,
            references: references
        )
    }

    private func adding(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw SIDXParserError.integerOverflow
        }
        return result
    }
}

/// 在 `data` 上按大端顺序前进读取的游标，越界即抛 `truncated`。
private struct BigEndianReader {
    let data: Data
    private(set) var offset = 0

    var remainingByteCount: Int {
        data.count - offset
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, remainingByteCount >= count else {
            throw SIDXParserError.truncated
        }
        offset += count
    }

    mutating func readUInt8() throws -> UInt8 {
        guard remainingByteCount >= 1 else {
            throw SIDXParserError.truncated
        }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        var result: UInt16 = 0
        for _ in 0..<2 {
            result = (result << 8) | UInt16(try readUInt8())
        }
        return result
    }

    mutating func readUInt32() throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<4 {
            result = (result << 8) | UInt32(try readUInt8())
        }
        return result
    }

    mutating func readUInt64() throws -> UInt64 {
        var result: UInt64 = 0
        for _ in 0..<8 {
            result = (result << 8) | UInt64(try readUInt8())
        }
        return result
    }
}
