import BiliAPI
import BiliApplication
import BiliNetworking
import Foundation
import Testing

@Suite
struct BiliWatchHistoryRepositoryTests {
    @Test(
        "API failures retain their application-level category",
        arguments: [
            MappingCase(
                scenario: .authorizationRequired,
                expected: .authenticationRequired
            ),
            MappingCase(
                scenario: .apiRejected(code: -101),
                expected: .authenticationRequired
            ),
            MappingCase(
                scenario: .apiRejected(code: -412),
                expected: .requestRestricted
            ),
            MappingCase(
                scenario: .apiRejected(code: -403),
                expected: .requestRestricted
            ),
            MappingCase(
                scenario: .apiRejected(code: -500),
                expected: .serviceRejected(code: -500)
            ),
            MappingCase(
                scenario: .httpStatus(500),
                expected: .transportFailure
            ),
            MappingCase(
                scenario: .invalidRequest,
                expected: .invalidResponse
            )
        ]
    )
    func mapsAPIFailure(testCase: MappingCase) async {
        let repository = testCase.scenario.repository()

        do {
            _ = try await repository.watchHistory(
                after: nil,
                pageSize: testCase.scenario.pageSize
            )
            Issue.record("Expected repository to throw")
        } catch let error as WatchHistoryError {
            #expect(error == testCase.expected)
        } catch {
            Issue.record("Unexpected error type: \(type(of: error))")
        }
    }

    @Test
    func preservesCancellation() async {
        let repository = HistoryScenario.cancellation.repository()

        await #expect(throws: CancellationError.self) {
            try await repository.watchHistory(after: nil, pageSize: 20)
        }
    }

    @Test
    func mapsUnknownTransportFailureToTransportFailure() async {
        let repository = HistoryScenario.unknownTransportFailure.repository()

        await #expect(throws: WatchHistoryError.transportFailure) {
            try await repository.watchHistory(after: nil, pageSize: 20)
        }
    }
}

struct MappingCase: Sendable, CustomTestStringConvertible {
    let scenario: HistoryScenario
    let expected: WatchHistoryError

    var testDescription: String {
        "\(scenario) -> \(expected)"
    }
}

enum HistoryScenario: Sendable, Equatable {
    case authorizationRequired
    case apiRejected(code: Int)
    case httpStatus(Int)
    case invalidRequest
    case cancellation
    case unknownTransportFailure

    var pageSize: Int {
        switch self {
        case .invalidRequest:
            0
        default:
            20
        }
    }

    func repository() -> BiliWatchHistoryRepository {
        // 空 reply 队列让 transport 抛出未知错误。
        let replies: [StubTransport.Reply] =
            switch self {
            case .apiRejected(let code):
                [.response(jsonResponse("{\"code\":\(code),\"message\":\"fixture\"}"))]
            case .httpStatus(let status):
                [.response(HTTPResponse(statusCode: status, body: Data()))]
            case .cancellation:
                [.cancellation]
            case .authorizationRequired, .invalidRequest, .unknownTransportFailure:
                []
            }
        return BiliWatchHistoryRepository(
            client: BiliAPIClient(
                transport: StubTransport(replies),
                requestAuthorizer: self == .authorizationRequired ? nil : StubAuthorizer()
            )
        )
    }
}
