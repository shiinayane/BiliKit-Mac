import BiliApplication
import BiliModels
import Foundation

/// 播放器信息（`/x/player/wbi/v2`）：字幕目录与分段章节读同一个 endpoint，各自解码自己的字段。
///
/// 两者分开请求、不共用一次响应：字幕目录只按账户读取，在播放 bridge 里限时等待（见 `DASHToHLSBridge`）；
/// 分段章节无凭据时也要读，归播放页的章节模型。凭据规则不同，合成一次请求就得让其中一方迁就另一方。
extension BiliAPIClient {
    /// 播放器信息只含轨道、章节等元数据；超出按响应异常失败关闭。
    private static let maximumPlayerInfoSize = 1 * 1_024 * 1_024

    /// 分段章节：有凭据时按账户读取，本地无凭据时匿名请求同一 endpoint（登录增强读取，见 SECURITY-MODEL §3）。
    func videoChapters(for identity: PlaybackItemIdentity) async throws -> [VideoChapter] {
        let payload: VideoChapterCatalogPayload = try await playerInfo(
            for: identity,
            missingCredential: .useAnonymousRequest
        )
        return payload.chapters()
    }

    /// 读某个分 P 的播放器信息；无效的 BV 与 CID 不发请求。
    func playerInfo<Payload: Decodable & Sendable>(
        for identity: PlaybackItemIdentity,
        missingCredential: MissingCredentialBehavior
    ) async throws -> Payload {
        guard BVID.isValid(identity.bvid), identity.cid > 0 else {
            throw BiliAPIError.invalidRequest
        }
        return try await signedRequest(
            path: BiliAccountReadPath.playerInfo,
            parameters: {
                [
                    "bvid": identity.bvid,
                    "cid": String(identity.cid)
                ]
            },
            send: { url in
                try await get(
                    url: url,
                    referer: try Self.videoReferer(identity.bvid),
                    access: .accountRead(missingCredential: missingCredential),
                    maximumResponseSize: Self.maximumPlayerInfoSize
                )
            }
        )
    }
}
