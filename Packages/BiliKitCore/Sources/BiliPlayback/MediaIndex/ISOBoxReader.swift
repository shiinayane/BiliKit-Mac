import Foundation

/// ISO BMFF 字节里的一个 box：四字符类型，与正文（不含 box 头）在所读 `Data` 中的下标范围。
struct ISOBox {
    let type: String
    let payload: Range<Int>
}

/// box 头声明的大小越界、box 截断，或整数读取越出数据范围。
///
/// 只在本模块的解析器内部流转：调用方把它换成自己的“结构损坏”错误再抛出。
struct ISOBoxStructureError: Error, Equatable {}

/// 在一段已读入内存的有界 ISO BMFF 字节（如 fMP4 init）上列出 box 表、按大端读取整数。
///
/// 只做结构遍历，每个偏移都做越界检查，不理解具体 box 的语义（sample entry 等由调用方解析），不复制
/// 数据。读取上限由读入数据的一方负责（见 `InitializationSegmentLoader`）。
struct ISOBoxReader {
    let data: Data

    /// `range` 内首尾相接的 box 序列；任何一个 box 越出 `range` 都让整张表失败。
    ///
    /// 大小为 0 的 box 延伸到 `range` 末尾，大小为 1 时读 64 位扩展大小，与 ISO/IEC 14496-12 一致。
    func boxes(in range: Range<Int>) throws -> [ISOBox] {
        guard range.lowerBound >= data.startIndex,
            range.upperBound <= data.endIndex
        else {
            throw ISOBoxStructureError()
        }
        var boxes: [ISOBox] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard range.upperBound - offset >= 8 else {
                throw ISOBoxStructureError()
            }
            let compactSize = try unsigned32(at: offset)
            let type = try boxType(at: offset + 4)
            let headerSize: Int
            let boxSize: Int
            switch compactSize {
            case 0:
                headerSize = 8
                boxSize = range.upperBound - offset
            case 1:
                let extendedSize = try unsigned64(at: offset + 8)
                guard extendedSize <= UInt64(Int.max) else {
                    throw ISOBoxStructureError()
                }
                headerSize = 16
                boxSize = Int(extendedSize)
            default:
                headerSize = 8
                boxSize = Int(compactSize)
            }
            guard boxSize >= headerSize,
                boxSize <= range.upperBound - offset
            else {
                throw ISOBoxStructureError()
            }
            let end = offset + boxSize
            boxes.append(
                ISOBox(
                    type: type,
                    payload: (offset + headerSize)..<end
                )
            )
            offset = end
        }
        return boxes
    }

    /// `parent` 正文里第一个类型为 `name` 的子 box；正文不是合法的 box 序列时失败。
    func child(named name: String, of parent: ISOBox) throws -> ISOBox? {
        try boxes(in: parent.payload).first { $0.type == name }
    }

    func unsigned8(at offset: Int) throws -> UInt8 {
        try bytes(at: offset, count: 1).first ?? 0
    }

    func unsigned16(at offset: Int) throws -> UInt16 {
        try bytes(at: offset, count: 2).reduce(0) { ($0 << 8) | UInt16($1) }
    }

    func unsigned32(at offset: Int) throws -> UInt32 {
        try bytes(at: offset, count: 4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func unsigned64(at offset: Int) throws -> UInt64 {
        try bytes(at: offset, count: 8).reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private func boxType(at offset: Int) throws -> String {
        guard
            let value = String(
                bytes: try bytes(at: offset, count: 4),
                encoding: .isoLatin1
            )
        else {
            throw ISOBoxStructureError()
        }
        return value
    }

    private func bytes(at offset: Int, count: Int) throws -> Data.SubSequence {
        guard offset >= data.startIndex, offset + count <= data.endIndex else {
            throw ISOBoxStructureError()
        }
        return data[offset..<(offset + count)]
    }
}
