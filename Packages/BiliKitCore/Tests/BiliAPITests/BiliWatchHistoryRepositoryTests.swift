import BiliAPI
import BiliApplication
import BiliNetworking
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct BiliWatchHistoryRepositoryTests {
    @Test(
        "API failures retain their application-level category",
        arguments: [
            MappingCase(
                scenario: .authorizationRequired,
                expected: .authenticationRequired
            ),
            // 带凭据的请求收到 -101 才是凭据失效；Keychain 等本地凭据读不到单独归类，不当作失效。
            MappingCase(
                scenario: .apiRejected(code: -101),
                expected: .authenticationInvalid
            ),
            MappingCase(
                scenario: .credentialUnavailable,
                expected: .authenticationUnavailable
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
                scenario: .invalidRequest,
                expected: .invalidRequest
            )
        ]
    )
    func mapsAPIFailure(testCase: MappingCase) async {
        let repository = testCase.scenario.repository()

        await #expect(throws: testCase.expected) {
            try await repository.watchHistory(
                after: nil,
                pageSize: testCase.scenario.pageSize
            )
        }
    }

    @Test
    func mapsUnknownTransportFailureToTransportFailure() async {
        let repository = HistoryScenario.unknownTransportFailure.repository()

        await #expect(throws: ContentApplicationError.transportFailure) {
            try await repository.watchHistory(after: nil, pageSize: 20)
        }
    }
}

struct MappingCase: Sendable, CustomTestStringConvertible {
    let scenario: HistoryScenario
    let expected: ContentApplicationError

    var testDescription: String {
        "\(scenario) -> \(expected)"
    }
}

enum HistoryScenario: Sendable, Equatable {
    case authorizationRequired
    case credentialUnavailable
    case apiRejected(code: Int)
    case invalidRequest
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
            case .authorizationRequired, .credentialUnavailable, .invalidRequest,
                .unknownTransportFailure:
                []
            }
        let authorizer: StubAuthorizer? =
            switch self {
            case .authorizationRequired: nil
            case .credentialUnavailable: StubAuthorizer(.fail(.unavailable))
            default: StubAuthorizer()
            }
        return BiliWatchHistoryRepository(
            client: BiliAPIClient(
                transport: StubTransport(replies),
                requestAuthorizer: authorizer
            )
        )
    }
}
