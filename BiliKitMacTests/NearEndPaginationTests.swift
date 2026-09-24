import Testing

@testable import BiliKit

struct NearEndPaginationTests {
    enum Step: CustomStringConvertible, Sendable {
        /// 以给定阈值状态评估一次，并断言是否请求下一页。
        case evaluate(
            inside: Bool,
            tail: Int?,
            loading: Bool = false,
            live: Bool = false,
            loads: Bool
        )
        case end(inside: Bool, loads: Bool)
        case releaseBackpressure
        case reset

        var description: String {
            switch self {
            case .evaluate(let inside, let tail, let loading, let live, let loads):
                "evaluate(inside: \(inside), tail: \(tail.map(String.init) ?? "nil"), "
                    + "loading: \(loading), live: \(live)) -> \(loads)"
            case .end(let inside, let loads): "end(inside: \(inside)) -> \(loads)"
            case .releaseBackpressure: "releaseBackpressure"
            case .reset: "reset"
            }
        }
    }

    struct Scenario: CustomStringConvertible, Sendable {
        let description: String
        let steps: [Step]
    }

    static let scenarios: [Scenario] = [
        Scenario(
            description: "同一尾部只触发一次，离开阈值后也不重复",
            steps: [
                .evaluate(inside: false, tail: 1, loads: false),
                .evaluate(inside: true, tail: 1, loads: true),
                .evaluate(inside: true, tail: 1, loads: false),
                .evaluate(inside: false, tail: 1, loads: false),
                .evaluate(inside: true, tail: 1, loads: false)
            ]
        ),
        Scenario(
            description: "加载中不触发",
            steps: [
                .evaluate(inside: true, tail: 1, loading: true, loads: false),
                .evaluate(inside: false, tail: 1, loads: false),
                .evaluate(inside: true, tail: 1, loads: true)
            ]
        ),
        Scenario(
            description: "仍在阈值内换尾部时必须先离开阈值再布防",
            steps: [
                .evaluate(inside: true, tail: 1, loads: true),
                .evaluate(inside: true, tail: 1, loading: true, loads: false),
                .evaluate(inside: true, tail: 2, loads: false),
                .evaluate(inside: true, tail: 2, loads: false),
                .evaluate(inside: false, tail: 2, loads: false),
                .evaluate(inside: true, tail: 2, loads: true)
            ]
        ),
        Scenario(
            description: "阈值外换尾部后首次进入即触发",
            steps: [
                .evaluate(inside: true, tail: 1, loads: true),
                .evaluate(inside: false, tail: 2, loads: false),
                .evaluate(inside: true, tail: 2, loads: true)
            ]
        ),
        Scenario(
            description: "没有更多内容时永不触发",
            steps: [
                .end(inside: true, loads: false),
                .evaluate(inside: true, tail: nil, loads: false),
                .end(inside: false, loads: false),
                .end(inside: true, loads: false)
            ]
        ),
        Scenario(
            description: "一次实时滚动手势最多自动加载一页",
            steps: [
                .evaluate(inside: true, tail: 1, live: true, loads: true),
                .evaluate(inside: false, tail: 2, live: true, loads: false),
                .evaluate(inside: true, tail: 2, live: true, loads: false),
                .releaseBackpressure,
                .evaluate(inside: false, tail: 2, live: true, loads: false),
                .evaluate(inside: true, tail: 2, live: true, loads: true)
            ]
        ),
        Scenario(
            description: "非实时滚动触发不产生背压",
            steps: [
                .evaluate(inside: true, tail: 1, loads: true),
                .evaluate(inside: false, tail: 2, loads: false),
                .evaluate(inside: true, tail: 2, loads: true)
            ]
        ),
        Scenario(
            description: "reset 同时解除背压并重新布防",
            steps: [
                .evaluate(inside: true, tail: 1, live: true, loads: true),
                .evaluate(inside: true, tail: 2, live: true, loads: false),
                .reset,
                .evaluate(inside: true, tail: 2, live: true, loads: true)
            ]
        )
    ]

    @Test(arguments: scenarios)
    func pagingFollowsThresholdAndGestureContract(_ scenario: Scenario) {
        var pagination = NearEndPagination<Int>()
        for (index, step) in scenario.steps.enumerated() {
            switch step {
            case .evaluate(let inside, let tail, let loading, let live, let loads):
                let result = pagination.shouldLoadMore(
                    isInsideThreshold: inside,
                    state: NearEndTailState(
                        canLoadMore: true,
                        tailIdentity: tail,
                        isLoading: loading
                    ),
                    isLiveScrolling: live
                )
                #expect(result == loads, "step \(index): \(step)")
            case .end(let inside, let loads):
                let result = pagination.shouldLoadMore(
                    isInsideThreshold: inside,
                    state: .end,
                    isLiveScrolling: false
                )
                #expect(result == loads, "step \(index): \(step)")
            case .releaseBackpressure:
                pagination.releaseBackpressure()
            case .reset:
                pagination.reset()
            }
        }
    }
}
