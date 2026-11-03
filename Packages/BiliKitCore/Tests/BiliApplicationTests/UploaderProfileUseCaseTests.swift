import BiliApplication
import BiliModels
import Foundation
import Testing

/// UP 主名片规范化名字与签名、其余字段原样保留，非正的 UP 主 ID 不发请求。
@Suite(.timeLimit(.minutes(1)))
struct UploaderProfileUseCaseTests {
    /// 名字与签名同一规则：折叠空白，空白视为缺省；用例重建名片时头像、大会员与计数原样保留。
    @Test(
        arguments: [
            ("  记录生活\n也记录技术  ", "记录生活 也记录技术"),
            (nil, nil),
            ("", nil),
            (" \t\n ", nil)
        ] as [(String?, String?)]
    )
    func normalizesNameAndSignatureAndKeepsOtherFields(
        remote: String?,
        expected: String?
    ) async throws {
        let avatarURL = try #require(URL(string: "https://i0.hdslb.com/bfs/face/fixture.jpg"))
        let useCase = UploaderProfileUseCase(
            repository: UploaderProfileRepositoryStub(
                result: UploaderProfile(
                    name: remote,
                    avatarURL: avatarURL,
                    signature: remote,
                    isVIP: true,
                    followerCount: 12,
                    videoCount: 3
                )
            )
        )

        #expect(
            try await useCase.profile(for: 10_001)
                == UploaderProfile(
                    name: expected,
                    avatarURL: avatarURL,
                    signature: expected,
                    isVIP: true,
                    followerCount: 12,
                    videoCount: 3
                )
        )
    }

    @Test
    func rejectsInvalidOwnerBeforeRepository() async {
        let repository = UploaderProfileRepositoryStub(result: UploaderProfile())
        let useCase = UploaderProfileUseCase(repository: repository)

        await #expect(throws: ContentApplicationError.invalidRequest) {
            try await useCase.profile(for: 0)
        }
        #expect(await repository.callCount == 0)
    }
}

private actor UploaderProfileRepositoryStub: UploaderProfileRepository {
    private let result: UploaderProfile
    private(set) var callCount = 0

    init(result: UploaderProfile) {
        self.result = result
    }

    func uploaderProfile(for ownerID: Int64) async throws -> UploaderProfile {
        callCount += 1
        return result
    }
}
