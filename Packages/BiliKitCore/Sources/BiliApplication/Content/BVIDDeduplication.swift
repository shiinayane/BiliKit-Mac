extension Array {
    /// 按 BVID 去重：丢弃与 `existing` 或自身前文重复的条目，保持原顺序。
    ///
    /// Feed 与历史分页共用；"本页没有新增条目"时怎样停止分页仍由各 Feature 自行决定。
    package func uniquedByBVID(
        after existing: [Element] = [],
        _ bvid: (Element) -> String
    ) -> [Element] {
        var seen = Set(existing.map(bvid))
        return filter { seen.insert(bvid($0)).inserted }
    }
}
