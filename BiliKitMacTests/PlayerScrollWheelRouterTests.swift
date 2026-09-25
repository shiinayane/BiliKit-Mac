import AppKit
import Testing

@testable import BiliKit

struct PlayerScrollWheelRouterTests {
    struct FakeWheel: PlayerScrollWheelInput, Sendable {
        let id: Int
        let scrollingDeltaX: CGFloat
        let scrollingDeltaY: CGFloat
        let phase: NSEvent.Phase
        let momentumPhase: NSEvent.Phase

        init(
            _ id: Int,
            _ deltaX: CGFloat,
            _ deltaY: CGFloat,
            phase: NSEvent.Phase = [],
            momentum: NSEvent.Phase = []
        ) {
            self.id = id
            scrollingDeltaX = deltaX
            scrollingDeltaY = deltaY
            self.phase = phase
            momentumPhase = momentum
        }
    }

    enum Step: Sendable {
        /// 输入一个事件，并期望路由器立即按顺序放出这些事件 id。
        case wheel(FakeWheel, releases: [Int])
        case cancel
    }

    struct Scenario: CustomTestStringConvertible, Sendable {
        let name: String
        let steps: [Step]

        var testDescription: String { name }
    }

    static let scenarios: [Scenario] = [
        Scenario(
            name: "纵向手势暂存开始阶段，锁定后横向抖动与惯性都交给外层",
            steps: [
                .wheel(FakeWheel(1, 0, 0, phase: .began), releases: []),
                .wheel(FakeWheel(2, 1, -12, phase: .changed), releases: [1, 2]),
                .wheel(FakeWheel(3, -20, -1, phase: .changed), releases: [3]),
                .wheel(FakeWheel(4, 0, 0, phase: .ended), releases: [4]),
                .wheel(FakeWheel(5, -8, -1, momentum: .began), releases: [5]),
                .wheel(FakeWheel(6, 0, -6, momentum: .changed), releases: [6]),
                .wheel(FakeWheel(7, 0, 0, momentum: .ended), releases: [7])
            ]
        ),
        Scenario(
            name: "mayBegin 与 began 都暂存到轴向确定后按序放出",
            steps: [
                .wheel(FakeWheel(1, 0, 0, phase: .mayBegin), releases: []),
                .wheel(FakeWheel(2, 0, 0, phase: .began), releases: []),
                .wheel(FakeWheel(3, 0, -3, phase: .changed), releases: [1, 2, 3])
            ]
        ),
        Scenario(
            name: "横向手势连同后续纵向位移与惯性整体丢弃",
            steps: [
                .wheel(FakeWheel(1, 0, 0, phase: .began), releases: []),
                .wheel(FakeWheel(2, -12, 1, phase: .changed), releases: []),
                .wheel(FakeWheel(3, 0, -30, phase: .changed), releases: []),
                .wheel(FakeWheel(4, 0, 0, phase: .ended), releases: []),
                .wheel(FakeWheel(5, 0, -10, momentum: .changed), releases: []),
                .wheel(FakeWheel(6, 0, 0, momentum: .ended), releases: []),
                .wheel(FakeWheel(7, 0, -5), releases: [7])
            ]
        ),
        Scenario(
            name: "斜向抖动累积到最小行程与领先量后才决定",
            steps: [
                .wheel(FakeWheel(1, 0, 0, phase: .began), releases: []),
                .wheel(FakeWheel(2, 0.3, -0.4, phase: .changed), releases: []),
                .wheel(FakeWheel(3, 1, -0.9, phase: .changed), releases: []),
                .wheel(
                    FakeWheel(4, 0.1, -1.6, phase: .changed),
                    releases: [1, 2, 3, 4]
                )
            ]
        ),
        Scenario(
            name: "未定轴向即抬手且横向占优时整体丢弃，惯性随之丢弃",
            steps: [
                .wheel(FakeWheel(1, 0, 0, phase: .began), releases: []),
                .wheel(FakeWheel(2, 0.3, -0.2, phase: .changed), releases: []),
                .wheel(FakeWheel(3, 0, 0, phase: .ended), releases: []),
                .wheel(FakeWheel(4, 0, -9, momentum: .changed), releases: [])
            ]
        ),
        Scenario(
            name: "未定轴向即抬手且纵向占优时交出全部，惯性随之交出",
            steps: [
                .wheel(FakeWheel(1, 0, 0, phase: .began), releases: []),
                .wheel(FakeWheel(2, 0.2, -0.3, phase: .changed), releases: []),
                .wheel(FakeWheel(3, 0, 0, phase: .ended), releases: [1, 2, 3]),
                .wheel(FakeWheel(4, -9, 0, momentum: .changed), releases: [4])
            ]
        ),
        Scenario(
            name: "没有位移的轻触把阶段事件交给外层",
            steps: [
                .wheel(FakeWheel(1, 0, 0, phase: .mayBegin), releases: []),
                .wheel(FakeWheel(2, 0, 0, phase: .cancelled), releases: [1, 2])
            ]
        ),
        Scenario(
            name: "手势以 cancelled 结束时决定不延续到之后的事件",
            steps: [
                .wheel(FakeWheel(1, 0, -4, phase: .began), releases: [1]),
                .wheel(FakeWheel(2, 0, 0, phase: .cancelled), releases: [2]),
                .wheel(FakeWheel(3, -6, 0, momentum: .changed), releases: [])
            ]
        ),
        Scenario(
            name: "cancel 丢弃暂存事件与本次手势剩余部分，下一次手势重新开始",
            steps: [
                .wheel(FakeWheel(1, 0, 0, phase: .began), releases: []),
                .cancel,
                .wheel(FakeWheel(2, 0, -12, phase: .changed), releases: []),
                .wheel(FakeWheel(3, 0, 0, phase: .ended), releases: []),
                .wheel(FakeWheel(4, 0, -8, momentum: .changed), releases: []),
                .wheel(FakeWheel(5, 0, 0, phase: .began), releases: []),
                .wheel(FakeWheel(6, 0, -4, phase: .changed), releases: [5, 6])
            ]
        ),
        Scenario(
            name: "cancel 之后无阶段的鼠标滚轮立即恢复",
            steps: [
                .wheel(FakeWheel(1, 0, -3, phase: .changed), releases: [1]),
                .cancel,
                .wheel(FakeWheel(2, 0, -3), releases: [2])
            ]
        ),
        Scenario(
            name: "没有开始阶段的 changed 按首个事件立即锁定",
            steps: [
                .wheel(FakeWheel(1, 1, -12, phase: .changed), releases: [1]),
                .wheel(FakeWheel(2, -12, 1, phase: .changed), releases: [2])
            ]
        ),
        Scenario(
            name: "没有开始阶段的 ended 直接丢弃",
            steps: [
                .wheel(FakeWheel(1, 0, -3, phase: .ended), releases: [])
            ]
        ),
        Scenario(
            name: "鼠标滚轮逐个事件按轴向决定",
            steps: [
                .wheel(FakeWheel(1, 0, -3), releases: [1]),
                .wheel(FakeWheel(2, -3, 0), releases: []),
                .wheel(FakeWheel(3, 1, 4), releases: [3])
            ]
        )
    ]

    @Test(arguments: scenarios)
    func routerReleasesEventsInOrderByGestureAxis(_ scenario: Scenario) {
        var router = PlayerScrollWheelRouter<FakeWheel>()
        for (index, step) in scenario.steps.enumerated() {
            switch step {
            case .cancel:
                router.cancel()
            case .wheel(let event, let expected):
                #expect(router.route(event).map(\.id) == expected, "step \(index)")
            }
        }
    }

    @Test(arguments: [
        (CGFloat(0), CGFloat(0), true),
        (1, 1, true),
        (-1, 1, true),
        (1, -2, true),
        (2, 1, false),
        (-2, -1, false),
        (0.5, 0, false)
    ])
    func axisRuleTreatsTiesAndZeroDeltaPhaseEventsAsVertical(
        deltaX: CGFloat,
        deltaY: CGFloat,
        scrollsVertically: Bool
    ) {
        #expect(
            PlayerScrollWheelAxisRule.scrollsVertically(deltaX: deltaX, deltaY: deltaY)
                == scrollsVertically
        )
    }
}
