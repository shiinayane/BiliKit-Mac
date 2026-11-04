import Foundation

/// 网格卡片展示数据的缓存：同一位置的来源条目没变、且卡片建出不久时直接沿用，只为新追加或变化的条目重新格式化。
///
/// 网格包装在 SwiftUI `body` 里把整张列表映射成卡片；列表一长，每次 `body` 求值（翻页开始与完成各一次）都要把
/// 全部卡片的数字、日期与读屏标签重新格式化，首页滚到二十多页时单次约 40ms，列表越长越慢。由网格包装用 `@State`
/// 持有，跟包装同生命周期；按列表位置缓存，每次调用只留下这次列表里的位置，条目数不超过当前列表。
///
/// 按位置而不是卡片 ID：各来源的条目类型不都可按 ID 取，追加时前面的位置不变；中间插入或删除时其后的位置
/// 来源不再相等，按需重建，结果仍正确。
@MainActor
package final class NativeVideoCardCache<Source: Equatable> {
    /// 卡片里有「N 分钟前」这类相对时间：建出超过这个时长的卡片重新生成，文字最多晚一分钟。
    ///
    /// 调长则相对时间更可能过时；调短则翻页时更常整表重算。
    private static var maximumAge: TimeInterval { 60 }

    private struct Entry {
        let source: Source
        let card: NativeVideoCardPresentation
        let createdAt: Date
    }

    private var entries: [Entry] = []

    package init() {}

    /// 按顺序给出每个来源条目的卡片；同一位置的来源相等且未过期时沿用上次的卡片。
    package func cards(
        for sources: [Source],
        make: (Source) -> NativeVideoCardPresentation
    ) -> [NativeVideoCardPresentation] {
        let now = Date()
        var next: [Entry] = []
        next.reserveCapacity(sources.count)
        for (index, source) in sources.enumerated() {
            if entries.indices.contains(index) {
                let entry = entries[index]
                if entry.source == source, now.timeIntervalSince(entry.createdAt) < Self.maximumAge
                {
                    next.append(entry)
                    continue
                }
            }
            next.append(Entry(source: source, card: make(source), createdAt: now))
        }
        entries = next
        return next.map(\.card)
    }
}
