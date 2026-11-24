import BiliApplication

extension BiliAPIError {
    /// 内容类 adapter（`BiliContentRepository`、`BiliWatchHistoryRepository`、`BiliWatchLaterRepository`、
    /// `BiliFavoritesRepository`）唯一的错误映射：取消原样传播，`BiliAPIError` 按 `Failure` 分类，其余错误为
    /// `unavailable`。
    ///
    /// 收藏夹另有的两处专属映射写在它的 adapter 里。
    static func contentApplicationError(for error: any Error) -> any Error {
        domainError(
            for: error,
            fallback: ContentApplicationError.unavailable,
            ContentApplicationError.init
        )
    }
}

extension ContentApplicationError {
    /// 远端失败分类到内容域错误的唯一对应；是否复核、是否给重试由 `ContentApplicationError`
    /// 自己的属性决定。
    init(_ failure: BiliAPIError.Failure) {
        self =
            switch failure {
            case .invalidRequest:
                .invalidRequest
            case .authorizationRequired:
                .authenticationRequired
            case .authenticationInvalid:
                .authenticationInvalid
            case .authorizationUnavailable:
                .authenticationUnavailable
            case .transport:
                .transportFailure
            case .unexpectedHTTPStatus:
                .unavailable
            case .restricted(let restriction):
                .requestRestricted(restriction)
            case .contentUnavailable:
                .contentUnavailable
            case .rejected(let code):
                .serviceRejected(code: code)
            case .unsupportedMedia:
                .unsupportedMedia
            case .noPlayableMedia:
                .playbackUnavailable
            case .invalidResponse:
                .invalidResponse
            }
    }
}
