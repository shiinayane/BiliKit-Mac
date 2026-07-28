import BiliAPI
import BiliApplication
import Testing

@Suite
struct BiliWatchHistoryRepositoryTests {
    @Test(
        "API failures retain their application-level category",
        arguments: [
            MappingCase(
                source: .authorizationRequired,
                expected: .authenticationRequired
            ),
            MappingCase(
                source: .apiRejected(code: -101, message: "fixture"),
                expected: .authenticationRequired
            ),
            MappingCase(
                source: .apiRejected(code: -412, message: "fixture"),
                expected: .requestRestricted
            ),
            MappingCase(
                source: .apiRejected(code: -403, message: "fixture"),
                expected: .requestRestricted
            ),
            MappingCase(
                source: .apiRejected(code: -500, message: "fixture"),
                expected: .serviceRejected(code: -500)
            ),
            MappingCase(
                source: .transportFailure,
                expected: .transportFailure
            ),
            MappingCase(
                source: .invalidRequest,
                expected: .invalidResponse
            ),
        ]
    )
    func mapsAPIFailure(testCase: MappingCase) async {
        let repository = BiliWatchHistoryRepository(
            service: HistoryServiceStub(outcome: .apiError(testCase.source))
        )

        do {
            _ = try await repository.watchHistory(after: nil, pageSize: 20)
            Issue.record("Expected repository to throw")
        } catch let error as WatchHistoryError {
            #expect(error == testCase.expected)
        } catch {
            Issue.record("Unexpected error type: \(type(of: error))")
        }
    }

    @Test
    func preservesCancellation() async {
        let repository = BiliWatchHistoryRepository(
            service: HistoryServiceStub(outcome: .cancellation)
        )

        await #expect(throws: CancellationError.self) {
            try await repository.watchHistory(after: nil, pageSize: 20)
        }
    }

    @Test
    func mapsUnknownFailureToTransportFailure() async {
        let repository = BiliWatchHistoryRepository(
            service: HistoryServiceStub(outcome: .unknownError)
        )

        await #expect(throws: WatchHistoryError.transportFailure) {
            try await repository.watchHistory(after: nil, pageSize: 20)
        }
    }
}

struct MappingCase: Sendable, CustomTestStringConvertible {
    let source: BiliAPIError
    let expected: WatchHistoryError

    var testDescription: String {
        "\(source) -> \(expected)"
    }
}

private struct HistoryServiceStub: BiliWatchHistoryService {
    enum Outcome: Sendable {
        case apiError(BiliAPIError)
        case cancellation
        case unknownError
    }

    let outcome: Outcome

    func watchHistory(
        after continuation: WatchHistoryContinuation?,
        pageSize: Int
    ) async throws -> WatchHistoryPage {
        switch outcome {
        case .apiError(let error):
            throw error
        case .cancellation:
            throw CancellationError()
        case .unknownError:
            throw HistoryServiceStubError()
        }
    }
}

private struct HistoryServiceStubError: Error {}
