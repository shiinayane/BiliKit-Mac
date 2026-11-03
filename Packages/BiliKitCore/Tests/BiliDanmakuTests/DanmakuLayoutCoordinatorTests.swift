import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定布局表 owner 的契约：设置变化后在后台整张重排、一次替换；过期设置的结果被丢弃；晚到的上一段
/// 排进来后，表与从头连续排一致。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct DanmakuLayoutCoordinatorTests {
    @Test
    func settingsChangeReplacesTheWholeTable() async throws {
        let coordinator = DanmakuLayoutCoordinator()
        let changes = TableChangeRecorder(coordinator)
        coordinator.setSegments([1: denseEvents(segment: 1, count: 120, seed: 1)])
        coordinator.setParameters(parameters(width: 800))
        try await changes.wait(until: 1)

        coordinator.setParameters(parameters(width: 1_200))
        try await changes.wait(until: 2)

        let placements = try #require(coordinator.table[1]?.placements)
        #expect(!placements.isEmpty)
        #expect(placements.allSatisfy { $0.planningWidth == 1_200 })
    }

    /// 已有布局表时连改两次设置：第一次的任务在途时 generation 已经变了，它的结果被丢弃，表只换成最后
    /// 一次的设置。
    @Test
    func resultsForOutdatedSettingsAreDropped() async throws {
        let coordinator = DanmakuLayoutCoordinator()
        let changes = TableChangeRecorder(coordinator)
        coordinator.setSegments([1: denseEvents(segment: 1, count: 120, seed: 2)])
        coordinator.setParameters(parameters(width: 800))
        try await changes.wait(until: 1)

        coordinator.setParameters(parameters(width: 960))
        coordinator.setParameters(parameters(width: 640))
        try await changes.wait(until: 2)

        #expect(coordinator.layoutParameters == parameters(width: 640))
        #expect(changes.parameters == [parameters(width: 800), parameters(width: 640)])
    }

    /// 任务进行中某段换了内容：这次的结果不收这一段，随后按新内容重排。
    @Test
    func segmentReplacedDuringAJobIsLaidOutAgain() async throws {
        let coordinator = DanmakuLayoutCoordinator()
        let changes = TableChangeRecorder(coordinator)
        let original = denseEvents(segment: 1, count: 120, seed: 6)
        let replacement = original.map {
            danmakuEvent(
                id: "replacement-" + $0.id,
                time: $0.timeSeconds,
                mode: $0.mode,
                text: $0.text,
                fontSize: $0.fontSize,
                colorRGB: $0.colorRGB,
                colorStyle: $0.colorStyle,
                weight: $0.weight,
                isHighLike: $0.isHighLike,
                isUploader: $0.isUploader
            )
        }
        coordinator.setParameters(parameters(width: 800))
        coordinator.setSegments([1: original])
        coordinator.setSegments([1: replacement])
        try await changes.wait(until: 2)

        let ids = try #require(coordinator.table[1]?.placements.map(\.request.event.id))
        #expect(!ids.isEmpty)
        #expect(ids.allSatisfy { $0.hasPrefix("replacement-") })
    }

    @Test
    func lateEarlierSegmentGivesTheSameTableAsContinuousLayout() async throws {
        let first = denseEvents(segment: 1, count: 300, seed: 4)
        let second = denseEvents(segment: 2, count: 300, seed: 5)
        let late = DanmakuLayoutCoordinator()
        let lateChanges = TableChangeRecorder(late)
        late.setParameters(parameters(width: 800))
        late.setSegments([2: second])
        try await lateChanges.wait(until: 1)
        late.setSegments([1: first, 2: second])
        try await lateChanges.wait(until: 2)

        let continuous = DanmakuLayoutCoordinator()
        let continuousChanges = TableChangeRecorder(continuous)
        continuous.setParameters(parameters(width: 800))
        continuous.setSegments([1: first, 2: second])
        try await continuousChanges.wait(until: 1)

        #expect(late.table[1]?.placements == continuous.table[1]?.placements)
        #expect(late.table[2]?.placements == continuous.table[2]?.placements)
    }

    private func parameters(width: Double) -> DanmakuLayoutParameters {
        DanmakuLayoutParameters(
            configuration: configuration(planningWidth: width),
            speedLevel: .default,
            backingScale: 2,
            filter: DanmakuFilter()
        )
    }
}

/// 记录布局表的每次替换及当时的设置，可等替换次数达到某个值。
@MainActor
final class TableChangeRecorder {
    private(set) var parameters: [DanmakuLayoutParameters?] = []
    private let counter = TestEventCounter()

    init(_ coordinator: DanmakuLayoutCoordinator) {
        coordinator.tableDidChange = { [weak self, weak coordinator] in
            self?.parameters.append(coordinator?.layoutParameters)
            Task { await self?.counter.signal() }
        }
    }

    func wait(until count: Int) async throws {
        try await counter.wait(until: count)
    }
}
