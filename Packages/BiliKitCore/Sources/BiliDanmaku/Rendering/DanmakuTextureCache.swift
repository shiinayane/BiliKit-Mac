import Foundation

final class DanmakuTextureLRUCache {
    struct Limits: Sendable, Equatable {
        // One item matches the rasterizer's 8 MiB bound. The 32 MiB total holds at
        // least four maximum accepted items while remaining small
        // compared with the 640-layer presentation ceiling.
        static let production = Limits(
            maximumItemCost: DanmakuTextureRasterizer.maximumTextureByteCost,
            maximumTotalCost: 32 * 1_024 * 1_024
        )

        let maximumItemCost: Int
        let maximumTotalCost: Int
    }

    private final class Node {
        let key: DanmakuTextureCacheKey
        let payload: DanmakuTexturePayload
        weak var previous: Node?
        var next: Node?

        init(
            key: DanmakuTextureCacheKey,
            payload: DanmakuTexturePayload
        ) {
            self.key = key
            self.payload = payload
        }
    }

    let limits: Limits
    private(set) var totalCost = 0
    private(set) var hitCount = 0
    private(set) var missCount = 0
    private(set) var evictionCount = 0
    private var entries: [DanmakuTextureCacheKey: Node] = [:]
    private var mostRecentlyUsed: Node?
    private var leastRecentlyUsed: Node?

    init(limits: Limits = .production) {
        precondition(limits.maximumItemCost > 0)
        precondition(limits.maximumTotalCost >= limits.maximumItemCost)
        self.limits = limits
    }

    var count: Int { entries.count }

    func value(
        for key: DanmakuTextureCacheKey
    ) -> DanmakuTexturePayload? {
        guard let node = entries[key] else {
            missCount += 1
            return nil
        }
        moveToFront(node)
        hitCount += 1
        return node.payload
    }

    @discardableResult
    func insert(
        _ payload: DanmakuTexturePayload,
        for key: DanmakuTextureCacheKey
    ) -> Bool {
        guard payload.byteCost <= limits.maximumItemCost else { return false }
        if let existing = entries[key] {
            remove(existing)
        }
        while totalCost + payload.byteCost > limits.maximumTotalCost,
            let oldest = leastRecentlyUsed
        {
            remove(oldest)
            evictionCount += 1
        }
        guard totalCost + payload.byteCost <= limits.maximumTotalCost else {
            return false
        }
        let node = Node(key: key, payload: payload)
        entries[key] = node
        insertAtFront(node)
        totalCost += payload.byteCost
        return true
    }

    func removeAll() {
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
        totalCost -= node.payload.byteCost
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
