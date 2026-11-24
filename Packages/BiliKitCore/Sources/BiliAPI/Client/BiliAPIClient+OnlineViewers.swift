import BiliApplication
import BiliModels
import Foundation

/// 播放页的「正在看」人数。
extension BiliAPIClient {
    /// 响应只有两三个短字段；超出按响应异常失败关闭。
    private static let maximumOnlineViewerResponseSize = 64 * 1_024

    /// 某个分 P 此刻的「正在看」人数文本；B 站不显示时为 nil。
    ///
    /// 始终匿名读取：公开的统计数字与观看者无关，不带账号 Cookie、不签 WBI，也不带设备 Cookie
    /// （`unlinkedAnonymous`，见 SECURITY-MODEL §3）。无效的 BV 与 CID 不发请求。
    func onlineViewerText(for identity: PlaybackItemIdentity) async throws -> String? {
        guard BVID.isValid(identity.bvid), identity.cid > 0 else {
            throw BiliAPIError.invalidRequest
        }
        let payload: OnlineViewerPayload = try await get(
            url: try endpoint(
                path: "/x/player/online/total",
                queryItems: [
                    URLQueryItem(name: "bvid", value: identity.bvid),
                    URLQueryItem(name: "cid", value: String(identity.cid))
                ]
            ),
            referer: try Self.videoReferer(identity.bvid),
            access: .unlinkedAnonymous,
            maximumResponseSize: Self.maximumOnlineViewerResponseSize
        )
        return payload.totalText()
    }
}
