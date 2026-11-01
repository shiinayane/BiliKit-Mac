/// `CostBoundedLRUCache` 的单项与总成本上限；成本的单位由调用方决定（字节，或每项记 1 的条数）。
package struct CostBoundedLRUCacheLimits: Sendable, Equatable {
    /// 单项成本上限；超过它的值不进入缓存。
    package let maximumItemCost: Int
    /// 全部条目的成本合计上限；不小于单项上限，所以任何合格的单项都放得进空缓存。
    package let maximumTotalCost: Int

    package init(maximumItemCost: Int, maximumTotalCost: Int) {
        precondition(maximumItemCost > 0)
        precondition(maximumTotalCost >= maximumItemCost)
        self.maximumItemCost = maximumItemCost
        self.maximumTotalCost = maximumTotalCost
    }
}

/// 按成本有界的 LRU 内存缓存：每项带一个非负成本，总成本放不下新值时从最久未用的一项开始淘汰。
///
/// 弹幕纹理（按像素字节）与播放详情区行高（每项记 1，总上限即条数上限）共用这一实现，不各自维护链表。
/// 拥有条目、最近使用顺序与成本合计；不拥有成本的含义与上限取值（由调用方给出），也不监听系统内存压力：
/// 需要时由持有它的 owner 调用 `removeAll()`。
///
/// 不变量：
/// - `totalCost` 恒等于缓存中各项成本之和，且不超过 `limits.maximumTotalCost`；
/// - 成本超过 `limits.maximumItemCost` 的值从不进入缓存，也不挤掉已有条目；
/// - 淘汰只发生在 `insert` 里，顺序只由 `value(for:)` 与 `insert` 的调用顺序决定（二者都把该项记为
///   最近使用）。不用 `NSCache`：它在调用方不知情时、按不保证的顺序淘汰，调用方无法依赖“刚放进去的
///   值在下一次 `insert` 之前一定取得到”，测试也无法固定淘汰结果。
///
/// 只在 MainActor 上使用，自身不加锁。
@MainActor
package final class CostBoundedLRUCache<Key: Hashable, Value> {
    /// 最近使用顺序的双向链表节点：`previous` 弱引用，避免相邻节点互相强引用成环；强引用来自
    /// `entries` 与 `next` 链。
    private final class Node {
        let key: Key
        let value: Value
        let cost: Int
        weak var previous: Node?
        var next: Node?

        init(key: Key, value: Value, cost: Int) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    package let limits: CostBoundedLRUCacheLimits
    package private(set) var totalCost = 0
    private var entries: [Key: Node] = [:]
    private var mostRecentlyUsed: Node?
    private var leastRecentlyUsed: Node?

    package init(limits: CostBoundedLRUCacheLimits) {
        self.limits = limits
    }

    package var count: Int { entries.count }

    /// 命中时把该项记为最近使用。
    package func value(for key: Key) -> Value? {
        guard let node = entries[key] else { return nil }
        moveToFront(node)
        return node.value
    }

    /// 放入或替换一项，并记为最近使用；返回是否放入。
    ///
    /// 成本超过单项上限时返回 false，已有的同 key 条目与其他条目都保持原样。否则先移除同 key 的旧值，
    /// 再从最久未用的一项开始淘汰，直到放得下。按条数计时 `cost` 用默认的 1。
    @discardableResult
    package func insert(_ value: Value, cost: Int = 1, for key: Key) -> Bool {
        precondition(cost >= 0)
        guard cost <= limits.maximumItemCost else { return false }
        if let existing = entries[key] {
            remove(existing)
        }
        while totalCost + cost > limits.maximumTotalCost, let oldest = leastRecentlyUsed {
            remove(oldest)
        }
        let node = Node(key: key, value: value, cost: cost)
        entries[key] = node
        insertAtFront(node)
        totalCost += cost
        return true
    }

    package func removeAll() {
        entries.removeAll(keepingCapacity: false)
        mostRecentlyUsed = nil
        leastRecentlyUsed = nil
        totalCost = 0
    }

    private func moveToFront(_ node: Node) {
        guard mostRecentlyUsed !== node else { return }
        unlink(node)
        insertAtFront(node)
    }

    private func remove(_ node: Node) {
        unlink(node)
        entries[node.key] = nil
        totalCost -= node.cost
    }

    private func unlink(_ node: Node) {
        let previous = node.previous
        let next = node.next
        previous?.next = next
        next?.previous = previous
        if mostRecentlyUsed === node {
            mostRecentlyUsed = next
        }
        if leastRecentlyUsed === node {
            leastRecentlyUsed = previous
        }
        node.previous = nil
        node.next = nil
    }

    private func insertAtFront(_ node: Node) {
        node.previous = nil
        node.next = mostRecentlyUsed
        mostRecentlyUsed?.previous = node
        mostRecentlyUsed = node
        if leastRecentlyUsed == nil {
            leastRecentlyUsed = node
        }
    }
}
