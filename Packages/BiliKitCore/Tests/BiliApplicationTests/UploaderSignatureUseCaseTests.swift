import BiliApplication
import Testing

struct UploaderSignatureUseCaseTests {
    @Test
    func normalizesPublicSignatureWhitespace() async throws {
        let useCase = UploaderSignatureUseCase(
            repository: UploaderSignatureRepositoryStub(
                result: "  记录生活\n也记录技术  "
            )
        )

        #expect(
            try await useCase.signature(for: 10_001)
                == "记录生活 也记录技术"
        )
    }

    @Test(arguments: [nil, "", " \t\n "])
    func emptyPublicSignatureBecomesAbsent(value: String?) async throws {
        let useCase = UploaderSignatureUseCase(
            repository: UploaderSignatureRepositoryStub(result: value)
        )

        #expect(try await useCase.signature(for: 10_001) == nil)
    }

    @Test
    func rejectsInvalidOwnerBeforeRepository() async {
        let repository = CountingUploaderSignatureRepository()
        let useCase = UploaderSignatureUseCase(repository: repository)

        await #expect(throws: GuestApplicationError.invalidRequest) {
            try await useCase.signature(for: 0)
        }
        #expect(await repository.callCount == 0)
    }
}

private struct UploaderSignatureRepositoryStub: UploaderSignatureRepository {
    let result: String?

    func signature(for ownerID: Int64) async throws -> String? {
        result
    }
}

private actor CountingUploaderSignatureRepository:
    UploaderSignatureRepository
{
    private(set) var callCount = 0

    func signature(for ownerID: Int64) async throws -> String? {
        callCount += 1
        return nil
    }
}
