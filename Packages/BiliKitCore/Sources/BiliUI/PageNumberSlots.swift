/// 页码条展开后显示的一格：一个页码，或折起来的连续页码（显示为省略号）。
package enum PageNumberSlot: Hashable, Sendable {
    case page(Int)
    case gap(ClosedRange<Int>)
}

/// 页码条展开时的页码排布：首页、末页、当前页前后各 `neighborCount` 页，其余折成省略号。
///
/// 来源列表的 `PageNumberPager` 与播放详情区楼中楼的页码条共用这一份排布。
package enum PageNumberSlots {
    /// 当前页两侧各显示两页：侧栏宽度下一行放得下，又能一步跳到附近的页。
    package static let neighborCount = 2

    /// 只省略一页时直接显示那一页：省略号并不比数字更短。
    package static func slots(currentPage: Int, pageCount: Int) -> [PageNumberSlot] {
        guard pageCount > 0 else { return [] }
        let current = min(max(1, currentPage), pageCount)
        let lower = max(1, current - neighborCount)
        let upper = min(pageCount, current + neighborCount)
        let pages = Set(lower...upper).union([1, pageCount]).sorted()
        var slots: [PageNumberSlot] = []
        var previous: Int?
        for page in pages {
            if let previous, page - previous > 1 {
                let hidden = (previous + 1)...(page - 1)
                slots.append(hidden.count == 1 ? .page(hidden.lowerBound) : .gap(hidden))
            }
            slots.append(.page(page))
            previous = page
        }
        return slots
    }
}
