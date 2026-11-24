import BiliApplication
import Testing

/// 各内容页（Browse、观看历史，以及今后的稍后再看与收藏夹）共用的“是否复核、是否重试”决定。
struct ContentApplicationErrorTests {
    @Test(
        arguments: [
            (ContentApplicationError.authenticationInvalid, true),
            (.authenticationRequired, false),
            (.authenticationUnavailable, false),
            (.requestRestricted(.httpStatus412), false),
            (.contentUnavailable, false),
            (.serviceRejected(code: -500), false)
        ]
    )
    func onlyInvalidCredentialsRequestAccountRevalidation(
        error: ContentApplicationError,
        revalidates: Bool
    ) {
        #expect(error.requiresAccountRevalidation == revalidates)
    }

    @Test(
        arguments: [
            (ContentApplicationError.contentUnavailable, false),
            (.authenticationRequired, false),
            (.invalidRequest, false),
            (.unsupportedMedia, false),
            (.fullViewingEntitlementRequired, false),
            (.authenticationUnavailable, true),
            (.authenticationInvalid, true),
            (.requestRestricted(.httpStatus412), true),
            (.serviceRejected(code: -500), true),
            (.transportFailure, true)
        ]
    )
    func outcomesThatRetryCannotChangeAreNotRetryable(
        error: ContentApplicationError,
        retryable: Bool
    ) {
        #expect(error.isRetryable == retryable)
    }
}
