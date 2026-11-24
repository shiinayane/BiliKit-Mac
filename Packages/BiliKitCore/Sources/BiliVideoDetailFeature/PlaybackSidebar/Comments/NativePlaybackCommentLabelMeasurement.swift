import AppKit
import BiliApplication

/// 评论行里单行标签的固有尺寸（`fittingSize`）：按文字、字体与断行方式取进程内缓存，缺失时用传入的标签量一次。
///
/// 评论行每次排版都要读元信息一行（时间、属地与各个操作）的宽度，改侧栏宽度时每帧都排；现量要为标签临时建一个
/// Auto Layout 引擎，这笔开销随可见评论数成倍放大。这些文字（日期、属地、赞数、动作名）在评论之间大量重复，复用的行
/// 换到另一条评论时多半能直接命中。
///
/// 只拥有“文字 → 尺寸”的映射，与具体评论无关，不随侧栏拆除清空。调用方只能传单行、不设 `preferredMaxLayoutWidth`
/// 的纯文字标签：键里没有富文本属性与换行宽度，这两样会改变尺寸。
@MainActor
enum NativePlaybackCommentLabelMeasurement {
    /// 标签当前文字的固有尺寸；空文字为 `.zero`。
    static func fittingSize(of label: NSTextField) -> NSSize {
        let text = label.stringValue
        guard !text.isEmpty, let font = label.font else { return .zero }
        let key = Key(text: text, font: font, lineBreakMode: label.lineBreakMode)
        if let size = sizes.value(for: key) { return size }
        let size = label.fittingSize
        sizes.insert(size, for: key)
        return size
    }

    private struct Key: Hashable {
        let text: String
        let font: NSFont
        let lineBreakMode: NSLineBreakMode
    }

    private static let sizes = CostBoundedLRUCache<Key, NSSize>(limits: .commentLabelSizes)
}

extension CostBoundedLRUCacheLimits {
    /// 评论行单行标签的尺寸缓存：每项成本记 1，最多 1024 项。
    ///
    /// 一屏评论的日期、属地与赞数远少于这个数；调小则滚过较多评论后回到前面时重新量字，调大只多占少量内存。
    static let commentLabelSizes = CostBoundedLRUCacheLimits(
        maximumItemCost: 1,
        maximumTotalCost: 1_024
    )
}
