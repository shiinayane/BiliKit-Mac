import AppKit
import BiliUI

typealias NativeVideoGridTailState = NearEndTailState<String>

struct NativeVideoGridUpdatePlan: Equatable {
    let identityChanged: Bool
    let insertedIDs: [String]
    let removedIDs: [String]
    let changedExistingIDs: Set<String>
    let isStrictTailAppend: Bool

    var animatesDifferences: Bool { identityChanged && !isStrictTailAppend }
    var restoresViewportAnchor: Bool { identityChanged && !isStrictTailAppend }

    init<Content: Equatable>(
        previousIDs: [String],
        previousContents: [String: Content],
        updatedIDs: [String],
        updatedContents: [String: Content]
    ) {
        identityChanged = previousIDs != updatedIDs
        let previousSet = Set(previousIDs)
        let updatedSet = Set(updatedIDs)
        insertedIDs = updatedIDs.filter { !previousSet.contains($0) }
        removedIDs = previousIDs.filter { !updatedSet.contains($0) }
        changedExistingIDs = Set(
            updatedIDs.filter {
                previousSet.contains($0) && previousContents[$0] != updatedContents[$0]
            }
        )
        isStrictTailAppend =
            updatedIDs.count > previousIDs.count
            && Array(updatedIDs.prefix(previousIDs.count)) == previousIDs
            && removedIDs.isEmpty
            && insertedIDs == Array(updatedIDs.dropFirst(previousIDs.count))
    }
}

struct NativeVideoGridScrollResetGate {
    private var requestID: UInt64

    init(initialRequestID: UInt64) {
        requestID = initialRequestID
    }

    mutating func consume(_ candidateRequestID: UInt64) -> Bool {
        guard candidateRequestID != requestID else { return false }
        requestID = candidateRequestID
        return true
    }
}

struct NativeVideoGridScrollResetState: Equatable {
    private(set) var requestID: UInt64 = 0
    var acknowledgedRequestID: UInt64 = 0

    mutating func request() {
        requestID &+= 1
    }
}

struct NativeVideoGridViewportAnchor: Equatable {
    let id: String
    let offsetFromViewportTop: CGFloat
}

enum NativeVideoGridAnchorRetention {
    static func targetOffsetY(
        itemOriginY: CGFloat,
        offsetFromViewportTop: CGFloat,
        minimumOffsetY: CGFloat = 0,
        maximumOffsetY: CGFloat
    ) -> CGFloat {
        min(
            max(minimumOffsetY, maximumOffsetY),
            max(minimumOffsetY, itemOriginY - offsetFromViewportTop)
        )
    }
}

struct NativeVideoScrollOffsetRetention {
    private(set) var offsetY: CGFloat
    private var persistedOffsetY: CGFloat

    init(initialOffsetY: CGFloat) {
        offsetY = max(0, initialOffsetY)
        persistedOffsetY = offsetY
    }

    mutating func record(_ offsetY: CGFloat) {
        self.offsetY = max(0, offsetY)
    }

    mutating func takePendingPersistence() -> CGFloat? {
        guard abs(offsetY - persistedOffsetY) > 0.5 else { return nil }
        persistedOffsetY = offsetY
        return offsetY
    }

    mutating func markPersisted(_ offsetY: CGFloat) {
        record(offsetY)
        persistedOffsetY = self.offsetY
    }
}

struct NativeVideoScrollBindingBridge {
    private(set) var synchronizedOffsetY: CGFloat

    init(initialOffsetY: CGFloat) {
        synchronizedOffsetY = max(0, initialOffsetY)
    }

    mutating func takeExternalRequest(_ offsetY: CGFloat) -> CGFloat? {
        let requestedOffsetY = max(0, offsetY)
        guard abs(requestedOffsetY - synchronizedOffsetY) > 0.5 else {
            return nil
        }
        synchronizedOffsetY = requestedOffsetY
        return requestedOffsetY
    }

    mutating func markSynchronized(_ offsetY: CGFloat) {
        synchronizedOffsetY = max(0, offsetY)
    }
}

struct NativeVideoGridOperationEpoch {
    private(set) var value: UInt64 = 0

    mutating func advance() -> UInt64 {
        value &+= 1
        return value
    }

    func accepts(_ candidate: UInt64) -> Bool {
        candidate == value
    }
}

/// 网格几何来自 BiliUI，与加载骨架共用；近尾部判断只属于原生网格。
typealias NativeVideoGridGeometry = VideoCardGridGeometry

extension VideoCardGridGeometry {
    static func nearEndTriggerIndex(
        itemCount: Int,
        width: CGFloat,
        prefetchRows: Int = 2
    ) -> Int? {
        guard itemCount > 0 else { return nil }
        let count = columnCount(for: width)
        return max(0, itemCount - count * max(1, prefetchRows))
    }

    static func isNearEnd(
        itemCount: Int,
        width: CGFloat,
        visibleMaximumY: CGFloat,
        prefetchRows: Int = 2
    ) -> Bool {
        guard
            isRenderableViewport(width: width),
            visibleMaximumY.isFinite,
            let triggerIndex = nearEndTriggerIndex(
                itemCount: itemCount,
                width: width,
                prefetchRows: prefetchRows
            )
        else { return false }
        let columns = columnCount(for: width)
        let triggerRow = triggerIndex / columns
        let triggerOriginY =
            topContentPadding
            + CGFloat(triggerRow) * (itemSize(for: width).height + verticalSpacing)
        return visibleMaximumY > triggerOriginY
    }
}
