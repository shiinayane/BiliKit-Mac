import BiliModels
import BiliNetworking
import Foundation

/// 写请求共用的管线（网页端的表单写入 `postForm`、App 端的 GET 写入 `getForWrite`），以及稍后再看与收藏的写入；点赞、
/// 投币与三连在 `BiliAPIClient+VideoEngagement`。
///
/// 表单编码与固定 header 只在 `postForm`，响应上限、状态 envelope 与 -101／-111 映射只在 `writeResponseBody` 一处，两条
/// 管线共用；各写 endpoint 只给出 path、字段、Referer 与授权方式。用户发起的写入只在注入了账户写授权器的 client（窗口主 API）上可用，并绑定窗口账户的 mid。
/// 写入不经 `signedRequest`、不重试；会话 epoch 的比对由请求管线 `response(baseRequest:...)` 统一执行，见
/// SECURITY-MODEL §3。
extension BiliAPIClient {
    /// 写请求的响应只有状态 envelope，16 KiB 远超正常大小；更大的正文按异常响应失败关闭。
    private static let maximumWriteResponseSize = 16 * 1_024
    /// 用户发起的写入固定带的 `Origin`，与授权器 `BiliAccountWriteRequestAuthorizer.origin` 相同。
    static let accountWriteOrigin = "https://www.bilibili.com"
    /// 加入稍后再看的 Referer：卡片可能来自任何页面，用固定的站点首页，不随来源变化。
    private static let watchLaterAddReferer = "https://www.bilibili.com/"
    /// 移除稍后再看的 Referer：与网页稍后再看页一致。
    private static let watchLaterRemoveReferer = "https://www.bilibili.com/watchlater/"
    /// 收藏写入的 Referer：面板与卡片菜单可能来自任何页面，用固定的站点首页。
    private static let favoriteWriteReferer = "https://www.bilibili.com/"

    /// 把视频加入 `accountID` 的稍后再看；凭据不属于该账户时由授权器拒绝，按凭据失效抛出。
    public func addToWatchLater(bvid: String, accountID: Int64) async throws {
        try await writeWatchLater(
            path: BiliAccountWritePath.watchLaterAdd,
            bvid: bvid,
            accountID: accountID,
            referer: Self.watchLaterAddReferer
        )
    }

    /// 从 `accountID` 的稍后再看移除一个视频（单条接口，见 `BiliAccountWritePath.watchLaterRemove`）。
    public func removeFromWatchLater(bvid: String, accountID: Int64) async throws {
        try await writeWatchLater(
            path: BiliAccountWritePath.watchLaterRemove,
            bvid: bvid,
            accountID: accountID,
            referer: Self.watchLaterRemoveReferer
        )
    }

    /// 把 `bvid` 加入 `adding` 里的收藏夹、移出 `removing` 里的收藏夹，一次请求完成；两侧至少一侧非空、互不相交。
    ///
    /// 空的一侧以空串发送、不省略，与网页一致。
    public func updateFavoriteMembership(
        bvid: String,
        adding: [Int64],
        removing: [Int64],
        accountID: Int64
    ) async throws {
        guard hasAccountWriteAuthorizer else {
            throw BiliAPIError.authorizationRequired
        }
        guard accountID > 0, BVID.isValid(bvid), let aid = BiliVideoAID.aid(fromBVID: bvid),
            !(adding.isEmpty && removing.isEmpty),
            Set(adding).isDisjoint(with: removing),
            (adding + removing).allSatisfy({ $0 > 0 })
        else {
            throw BiliAPIError.invalidRequest
        }
        try await postForm(
            url: try endpoint(path: BiliAccountWritePath.favoriteMembershipUpdate),
            fields: [
                ("rid", String(aid)),
                ("type", "2"),
                ("add_media_ids", adding.map(String.init).joined(separator: ",")),
                ("del_media_ids", removing.map(String.init).joined(separator: ",")),
                ("platform", "web")
            ],
            referer: Self.favoriteWriteReferer,
            origin: Self.accountWriteOrigin,
            access: .accountWrite(expectedAccountID: accountID)
        )
    }

    /// 从收藏夹 `folderID` 移除稿件 `aid` 这一个视频条目；用 av 号，失效视频没有 BVID 也能移除。
    public func removeFromFavoriteFolder(
        aid: Int64,
        folderID: Int64,
        accountID: Int64
    ) async throws {
        guard hasAccountWriteAuthorizer else {
            throw BiliAPIError.authorizationRequired
        }
        guard accountID > 0, aid > 0, folderID > 0 else {
            throw BiliAPIError.invalidRequest
        }
        try await postForm(
            url: try endpoint(path: BiliAccountWritePath.favoriteFolderEntryRemove),
            fields: [
                ("resources", "\(aid):2"),
                ("media_id", String(folderID)),
                ("platform", "web")
            ],
            referer: Self.favoriteWriteReferer,
            origin: Self.accountWriteOrigin,
            access: .accountWrite(expectedAccountID: accountID)
        )
    }

    /// 表单写请求的唯一管线：urlencoded 编码字段，固定 `Accept`、`Content-Type`、`Referer`、`User-Agent`（`origin` 给出时
    /// 另带 `Origin`），经 `access` 对应的授权器发出，再判定状态 envelope；成功时返回响应正文，需要 `data` 的写入自己解码。
    ///
    /// 写请求总是带凭据发出：业务码 -101（未登录）与 -111（csrf 校验失败）都说明凭据失效，映射为
    /// `authenticationInvalid`；其他非零码为 `apiRejected`。`code` 为 0 但 `data` 只有 `v_voucher` 是风控挑战、写入
    /// 没有生效，按 `riskControlVoucher`（受限）失败，不当作成功（见 SECURITY-MODEL §3）。不像 JSON 的正文（HTML 风控页等）按 `nonJSONResponse` 失败
    /// 关闭。调用方不得自行附加 csrf：授权器在拼好的表单末尾注入，表单里已有就拒绝。`additionalCookie` 在授权之后附加，
    /// 只给要求 `buvid3` 的点赞、投币与三连（见 SECURITY-MODEL §3）。
    @discardableResult
    func postForm(
        url: URL,
        fields: [(String, String)],
        referer: String,
        origin: String?,
        access: RequestAccess,
        additionalCookie: String? = nil
    ) async throws -> Data {
        var headers = [
            "Accept": "application/json",
            "Content-Type": "application/x-www-form-urlencoded",
            "Referer": referer,
            "User-Agent": userAgent
        ]
        if let origin {
            headers["Origin"] = origin
        }
        let authorizedResponse = try await response(
            baseRequest: HTTPRequest(
                url: url,
                method: .post,
                headers: headers,
                body: try Self.formBody(fields)
            ),
            access: access,
            maximumResponseSize: Self.maximumWriteResponseSize,
            additionalCookie: additionalCookie
        )
        return try writeResponseBody(authorizedResponse)
    }

    /// App 端写入的唯一管线：GET（App 端的写接口也是 GET），固定 `Accept` 与 `User-Agent`，经 `access`（`appWrite`）对应的
    /// 授权器签名发出，再按与表单写入相同的规则判定状态 envelope。
    ///
    /// 调用方只给出不含凭据与签名的 query；access_token 与签名由授权器写入。
    @discardableResult
    func getForWrite(url: URL, access: RequestAccess) async throws -> Data {
        let authorizedResponse = try await response(
            baseRequest: HTTPRequest(
                url: url,
                headers: ["Accept": "application/json", "User-Agent": userAgent]
            ),
            access: access,
            maximumResponseSize: Self.maximumWriteResponseSize
        )
        return try writeResponseBody(authorizedResponse)
    }

    /// 写请求响应的唯一判定，见 `postForm` 的说明：写请求总是带凭据发出，-101／-111 是凭据失效，`v_voucher` 是风控挑战。
    private func writeResponseBody(_ authorizedResponse: AuthorizedHTTPResponse) throws -> Data {
        guard authorizedResponse.response.looksLikeJSON(allowsTopLevelArray: true) else {
            throw BiliAPIError.nonJSONResponse
        }
        let status: APIStatusEnvelope
        do {
            status = try decoder.decode(
                APIStatusEnvelope.self,
                from: authorizedResponse.response.body
            )
        } catch {
            throw BiliAPIError.decodingFailed
        }
        if status.code == -101 || status.code == -111 {
            throw BiliAPIError.authenticationInvalid
        }
        guard status.code == 0 else {
            throw BiliAPIError.apiRejected(code: status.code, message: status.message ?? "")
        }
        if Self.isRiskControlVoucher(authorizedResponse.response.body) {
            throw BiliAPIError.riskControlVoucher
        }
        return authorizedResponse.response.body
    }

    /// 稍后再看写入的共同部分：BVID 在本地换算为 aid（写接口一律传 aid），表单只有 `aid`，csrf 由授权器注入。
    private func writeWatchLater(
        path: String,
        bvid: String,
        accountID: Int64,
        referer: String
    ) async throws {
        guard hasAccountWriteAuthorizer else {
            throw BiliAPIError.authorizationRequired
        }
        guard accountID > 0, BVID.isValid(bvid), let aid = BiliVideoAID.aid(fromBVID: bvid) else {
            throw BiliAPIError.invalidRequest
        }
        try await postForm(
            url: try endpoint(path: path),
            fields: [("aid", String(aid))],
            referer: referer,
            origin: Self.accountWriteOrigin,
            access: .accountWrite(expectedAccountID: accountID)
        )
    }

    private static func formBody(_ fields: [(String, String)]) throws -> Data {
        var components = URLComponents()
        components.queryItems = fields.map(URLQueryItem.init(name:value:))
        guard let encoded = components.percentEncodedQuery else {
            throw BiliAPIError.invalidRequest
        }
        return Data(encoded.utf8)
    }
}
