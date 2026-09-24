import BiliApplication
import Testing

struct UploaderSignatureUseCaseTests {
    @Test(
        arguments: [
            ("  记录生活\n也记录技术  ", "记录生活 也记录技术"),
            (nil, nil),
            ("", nil),
            (" \t\n ", nil)
        ] as [(String?, String?)]
    )
    func collapsesWhitespaceAndTreatsBlankSignatureAsAbsent(
        remote: String?,
        expected: String?
    ) async throws {
        let useCase = UploaderSignatureUseCase(
            repository: UploaderSignatureRepositoryStub(result: remote)
        )

        #expect(try await useCase.signature(for: 10_001) == expected)
    }

    @Test
    func rejectsInvalidOwnerBeforeRepository() async {
        let repository = UploaderSignatureRepositoryStub(result: nil)
        let useCase = UploaderSignatureUseCase(repository: repository)

        await #expect(throws: GuestApplicationError.invalidRequest) {
            try await useCase.signature(for: 0)
        }
        #expect(await repository.callCount == 0)
    }
}

private actor UploaderSignatureRepositoryStub: UploaderSignatureRepository {
    private let result: String?
    private(set) var callCount = 0

    init(result: String?) {
        self.result = result
    }

    func signature(for ownerID: Int64) async throws -> String? {
        callCount += 1
        return result
    }
}
