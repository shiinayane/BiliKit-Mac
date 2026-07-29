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
            ),
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

enum HistoryScenario: Sendable {
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
        let client: BiliAPIClient
        switch self {
        case .authorizationRequired:
            client = BiliAPIClient(
                transport: HistoryTransport(outcome: .unknownFailure)
            )
        case .apiRejected(let code):
            client = authorizedClient(
                outcome: .response(
                    HTTPResponse(
                        statusCode: 200,
                        headers: [
                            "Content-Type": "application/json; charset=utf-8"
                        ],
                        body: Data(
                            """
                            {"code":\(code),"message":"fixture"}
                            """.utf8
                        )
                    )
                )
            )
        case .httpStatus(let status):
            client = authorizedClient(
                outcome: .response(
                    HTTPResponse(
                        statusCode: status,
                        body: Data()
                    )
                )
            )
        case .invalidRequest:
            client = authorizedClient(outcome: .unknownFailure)
        case .cancellation:
            client = authorizedClient(outcome: .cancellation)
        case .unknownTransportFailure:
            client = authorizedClient(outcome: .unknownFailure)
        }
        return BiliWatchHistoryRepository(client: client)
    }

    private func authorizedClient(
        outcome: HistoryTransport.Outcome
    ) -> BiliAPIClient {
        BiliAPIClient(
            transport: HistoryTransport(outcome: outcome),
            requestAuthorizer: HistoryRequestAuthorizer()
        )
    }
}

private struct HistoryRequestAuthorizer: HTTPRequestAuthorizing {
    func authorize(_ request: HTTPRequest) -> HTTPRequest {
        request
    }
}

private struct HistoryTransport: HTTPTransport {
    enum Outcome: Sendable {
        case response(HTTPResponse)
        case cancellation
        case unknownFailure
    }

    let outcome: Outcome

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch outcome {
        case .response(let response):
            response
        case .cancellation:
            throw CancellationError()
        case .unknownFailure:
            throw HistoryTransportError()
        }
    }
}

private struct HistoryTransportError: Error {}
