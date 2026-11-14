import Foundation

/// 给 B 站杜比全景声 init 的 `dec3` 补上 JOC 标记，返回改写后的 init；形状与实测样本不同时返回 nil。
///
/// B 站全景声的 E-AC-3 码流带 JOC，但 init 的 `dec3` 只有 5 字节、缺 ETSI TS 102 366 附录 F.6 的
/// `flag_ec3_extension_type_a` 与 `complexity_index_type_a`；系统只按 init 的这两项决定是否按全景声
/// 渲染（实测：缺它们时控制中心显示“多声道”）。改写只在末尾补这 2 字节，并把 `dec3` 与它的每个祖先 box
/// 的长度加 2；分段不动，`moof` 的偏移都相对自身，不受影响。见 SECURITY-MODEL §5。
///
/// 只接受与实测一致的形状：唯一的 `moov/trak`、`stsd` 里唯一的 version 0 `ec-3`、其中唯一的 `dec3`
/// 正文恰好 5 字节、一个独立子流且没有依赖子流，祖先都用 32 位长度。其他形状（包括已经带扩展字节的）
/// 一律不改，调用方按普通杜比音频发布。结果必须恰好多 2 字节，且能再被完整遍历、读出音频格式。
enum EAC3JointObjectCodingMarker {
    /// 写进 `complexity_index_type_a` 的值，也是 master 里 `CHANNELS="<n>/JOC"` 的 n（Apple HLS Authoring
    /// Spec 要求两者相等）。
    ///
    /// B 站没有给出码流的真实复杂度；16 是 Apple 全景声参考流 init 里的取值，实测补上后系统按全景声渲染。
    /// 改变它只改这两处声明，不改码流。
    static let complexityIndex: UInt8 = 16
    /// 补在 `dec3` 末尾的字节：7 位保留加 `flag_ec3_extension_type_a = 1`，再是 `complexity_index_type_a`。
    private static let extensionBytes: [UInt8] = [0x01, complexityIndex]
    /// 不带扩展字节的 `dec3` 正文长度：2 字节 data_rate 与子流数，加一个没有依赖子流的独立子流 3 字节。
    private static let unmarkedConfigurationByteCount = 5
    /// AudioSampleEntry（version 0）固定字段长度，子 box 从这之后开始。
    private static let audioSampleEntryHeaderByteCount = 28
    /// 32 位长度的 box 头长度。
    private static let compactHeaderByteCount = 8

    static func marked(_ initialization: Data) -> Data? {
        let data = Data(initialization)
        let reader = ISOBoxReader(data: data)
        guard let path = try? configurationPath(in: reader),
            let marked = try? inserting(into: data, along: path, reader: reader),
            marked.count == data.count + extensionBytes.count,
            (try? AudioFormatMetadataParser().parse(marked)) != nil
        else {
            return nil
        }
        return marked
    }

    /// 从 `moov` 到 `dec3` 的 box 链（含两端）；任何一层不唯一或不符合实测形状都失败。
    private static func configurationPath(in reader: ISOBoxReader) throws -> [ISOBox] {
        let movie = try only("moov", in: reader.boxes(in: reader.data.indices))
        let track = try only("trak", in: reader.boxes(in: movie.payload))
        var path = [movie, track]
        var parent = track
        for type in ["mdia", "minf", "stbl", "stsd"] {
            guard let child = try reader.child(named: type, of: parent) else {
                throw ISOBoxStructureError()
            }
            path.append(child)
            parent = child
        }
        let description = parent
        guard description.payload.count >= 8,
            try reader.unsigned32(at: description.payload.lowerBound + 4) == 1
        else {
            throw ISOBoxStructureError()
        }
        let entries = try reader.boxes(
            in: (description.payload.lowerBound + 8)..<description.payload.upperBound
        )
        let entry = try only("ec-3", in: entries)
        guard entries.count == 1,
            entry.payload.count >= audioSampleEntryHeaderByteCount,
            try reader.unsigned16(at: entry.payload.lowerBound + 8) == 0
        else {
            throw ISOBoxStructureError()
        }
        let childrenStart = entry.payload.lowerBound + audioSampleEntryHeaderByteCount
        let children = childrenStart..<entry.payload.upperBound
        let configuration = try only("dec3", in: reader.boxes(in: children))
        let base = configuration.payload.lowerBound
        // 第 2 字节低 3 位是独立子流数减一，第 5 字节的 4 位是第一个独立子流的依赖子流数。
        guard configuration.payload.count == unmarkedConfigurationByteCount,
            try reader.unsigned8(at: base + 1) & 0x07 == 0,
            (try reader.unsigned8(at: base + 4) >> 1) & 0x0F == 0
        else {
            throw ISOBoxStructureError()
        }
        return path + [entry, configuration]
    }

    private static func only(_ type: String, in boxes: [ISOBox]) throws -> ISOBox {
        let matches = boxes.filter { $0.type == type }
        guard matches.count == 1 else { throw ISOBoxStructureError() }
        return matches[0]
    }

    /// 把每个 box 的 32 位长度加 2，再在最内层（`dec3`）末尾插入扩展字节；用 64 位或“延伸到末尾”长度的
    /// box 不改。
    private static func inserting(
        into data: Data,
        along path: [ISOBox],
        reader: ISOBoxReader
    ) throws -> Data {
        var result = data
        for box in path {
            let start = box.payload.lowerBound - compactHeaderByteCount
            let size = try reader.unsigned32(at: start)
            guard start >= data.startIndex,
                Int(size) == box.payload.upperBound - start,
                size <= UInt32.max - UInt32(extensionBytes.count)
            else {
                throw ISOBoxStructureError()
            }
            let grown = size + UInt32(extensionBytes.count)
            result.replaceSubrange(
                start..<(start + 4),
                with: withUnsafeBytes(of: grown.bigEndian) { Data($0) }
            )
        }
        guard let configuration = path.last else { throw ISOBoxStructureError() }
        result.insert(contentsOf: extensionBytes, at: configuration.payload.upperBound)
        return result
    }
}
