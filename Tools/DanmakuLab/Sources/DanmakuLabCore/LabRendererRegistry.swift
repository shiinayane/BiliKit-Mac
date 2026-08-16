import BiliDanmaku
import Foundation
import QuartzCore

public struct LabRendererID: RawRepresentable, Hashable, Sendable {
    public static let productionCoreAnimation = LabRendererID(
        rawValue: "production-core-animation"
    )

    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.isEmpty)
        self.rawValue = rawValue
    }
}

public enum LabRendererRole: Sendable, Equatable {
    case productionBaseline
    case candidate
}

@MainActor
public struct LabRendererInstance {
    public let backend: any DanmakuRenderingBackend
    public let surfaceLayer: CALayer

    public init(
        backend: any DanmakuRenderingBackend,
        surfaceLayer: CALayer
    ) {
        self.backend = backend
        self.surfaceLayer = surfaceLayer
    }
}

@MainActor
public struct LabRendererDescriptor: Identifiable {
    public let id: LabRendererID
    public let displayName: String
    public let role: LabRendererRole

    private let factory: @MainActor (CoreAnimationDanmakuStyle) -> LabRendererInstance

    public static let productionCoreAnimation = LabRendererDescriptor(
        id: .productionCoreAnimation,
        displayName: "Production Core Animation",
        role: .productionBaseline
    ) { style in
        let renderer = CoreAnimationDanmakuRenderer(style: style)
        return LabRendererInstance(
            backend: renderer,
            surfaceLayer: renderer.rootLayer
        )
    }

    public static func candidate(
        id: LabRendererID,
        displayName: String,
        factory:
            @escaping @MainActor (CoreAnimationDanmakuStyle) ->
            LabRendererInstance
    ) -> LabRendererDescriptor {
        precondition(id != .productionCoreAnimation)
        return LabRendererDescriptor(
            id: id,
            displayName: displayName,
            role: .candidate,
            factory: factory
        )
    }

    private init(
        id: LabRendererID,
        displayName: String,
        role: LabRendererRole,
        factory:
            @escaping @MainActor (CoreAnimationDanmakuStyle) ->
            LabRendererInstance
    ) {
        precondition(!displayName.isEmpty)
        self.id = id
        self.displayName = displayName
        self.role = role
        self.factory = factory
    }

    func makeRenderer(
        style: CoreAnimationDanmakuStyle
    ) -> LabRendererInstance {
        factory(style)
    }
}

@MainActor
public struct LabRendererRegistry {
    public let descriptors: [LabRendererDescriptor]

    public static let productionOnly = LabRendererRegistry()

    public init(candidates: [LabRendererDescriptor] = []) {
        precondition(candidates.allSatisfy { $0.role == .candidate })
        let candidateIDs = candidates.map(\.id)
        precondition(Set(candidateIDs).count == candidateIDs.count)
        descriptors = [.productionCoreAnimation] + candidates
    }

    public var baseline: LabRendererDescriptor {
        descriptors[0]
    }

    public var hasCandidates: Bool {
        descriptors.count > 1
    }

    public func descriptor(
        for id: LabRendererID
    ) -> LabRendererDescriptor? {
        descriptors.first { $0.id == id }
    }
}
