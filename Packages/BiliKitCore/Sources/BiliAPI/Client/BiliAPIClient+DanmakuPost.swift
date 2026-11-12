import BiliApplication
import BiliModels
import Foundation

/// 发送视频弹幕（`BiliAccountWritePath.danmakuPost`），经网页端表单写入管线 `postForm` 与账户写授权器发出。
extension BiliAPIClient {
    /// 弹幕写入的 Referer：与其他网页端写入一样用固定的站点首页，与授权器 schema 表一致。
    private static let danmakuPostReferer = "https://www.bilibili.com/"

    /// 以 `accountID` 的身份发一条弹幕，返回服务端给的弹幕 ID。
    ///
    /// `rnd` 取发出时刻的微秒时间戳（见 `BiliAccountWritePath.danmakuPost`）。
    public func postDanmaku(
        _ request: DanmakuPostRequest,
        accountID: Int64
    ) async throws -> String {
        guard hasAccountWriteAuthorizer else {
            throw BiliAPIError.authorizationRequired
        }
        guard accountID > 0, BVID.isValid(request.identity.bvid), request.identity.cid > 0,
            request.progressMilliseconds >= 0
        else {
            throw BiliAPIError.invalidRequest
        }
        let body = try await postForm(
            url: try endpoint(path: BiliAccountWritePath.danmakuPost),
            fields: [
                ("type", "1"),
                ("oid", String(request.identity.cid)),
                ("msg", request.text),
                ("bvid", request.identity.bvid),
                ("progress", String(request.progressMilliseconds)),
                ("color", String(request.colorRGB)),
                ("fontsize", String(Int(request.fontSize))),
                ("pool", "0"),
                ("mode", String(DanmakuWireValues.wireMode(for: request.mode))),
                ("rnd", String(Int64(Date().timeIntervalSince1970 * 1_000_000)))
            ],
            referer: Self.danmakuPostReferer,
            origin: Self.accountWriteOrigin,
            access: .accountWrite(expectedAccountID: accountID)
        )
        let payload: DanmakuPostPayload?
        do {
            payload = try decoder.decode(DanmakuPostEnvelope.self, from: body).data
        } catch {
            throw BiliAPIError.decodingFailed
        }
        guard let danmakuID = payload?.danmakuID else {
            throw BiliAPIError.missingData
        }
        return danmakuID
    }
}

private struct DanmakuPostEnvelope: Decodable, Sendable {
    let data: DanmakuPostPayload?
}

/// 发送成功的 `data`：优先取字符串形式的 `dmid_str`，数字形式的 `dmid` 超出双精度能精确表示的范围。
private struct DanmakuPostPayload: Decodable, Sendable {
    let danmakuID: String?

    private enum CodingKeys: String, CodingKey {
        case dmid
        case dmidString = "dmid_str"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `dmid_str` 形状不对时退回 `dmid`：发送已经成功，不能因为这个字段把结果说成失败。
        if let string = try? container.decodeIfPresent(String.self, forKey: .dmidString),
            let value = Int64(string), value > 0
        {
            danmakuID = String(value)
        } else if let value = try container.decodeIfPresent(FlexibleInt64.self, forKey: .dmid)?
            .value, value > 0
        {
            danmakuID = String(value)
        } else {
            danmakuID = nil
        }
    }
}
