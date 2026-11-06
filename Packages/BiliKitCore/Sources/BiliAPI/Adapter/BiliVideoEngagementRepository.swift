import BiliApplication

/// `VideoEngagementRepository` 的 B 站实现：转调窗口主 API 的互动读取与点赞、投币、三连、关注写入，并映射失败。
///
/// 无状态；写入要求底层 client 注入了 App 写授权器（点赞、投币、三连）与账户写授权器（关注），即 `LiveAPIClients.main`。读取失败经内容域映射；写入的共同映射在
/// `AccountWriteErrorMapping`，这里只给出这几个接口的业务码。取消原样传播。
public struct BiliVideoEngagementRepository: VideoEngagementRepository {
    /// 重复点赞（点赞时）与“取消点赞失败：用户未点赞”（取消时）：服务端已经是目标状态，按成功处理。
    ///
    /// 出处是网页端的接口文档与错误码表；App 端实测对已赞的视频再点赞直接返回 0，这两个码留作服务端改变行为时的兜底。
    private static let alreadyLikedCode = 65_006
    private static let notLikedCode = 65_004
    /// 投币的业务码：硬币不足、不能给自己投币、投币间隔太短、超过单个稿件投币上限。
    private static let coinsInsufficientCode = -104
    private static let ownVideoCode = 34_002
    private static let coinTooFrequentCode = 34_004
    private static let coinLimitCode = 34_005
    /// 稿件不存在。
    private static let missingVideoCode = 10_003
    /// 关注时“已经关注用户，无法重复关注”：服务端已经是目标状态，按成功处理。
    ///
    /// 出处是接口文档，未经本项目实测。取消关注没有对应的“已是目标状态”码，只按接口结果。
    private static let alreadyFollowingCode = 22_014
    /// 关注数已达上限；出处同上。
    private static let followLimitCode = 22_009
    /// 账号异常：B 站拒绝了这个客户端的这次操作（按稿件出现，网页上可以完成）。
    ///
    /// 通用映射把 -403 当作风控，这里先拦下。
    private static let declinedForClientCode = -403

    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func engagement(of target: VideoWriteTarget) async throws -> VideoEngagementState {
        do {
            return try await client.videoEngagement(bvid: target.bvid)
        } catch {
            throw BiliAPIError.contentApplicationError(for: error)
        }
    }

    public func setLiked(_ isLiked: Bool, target: VideoWriteTarget, accountID: Int64) async throws {
        do {
            try await client.setVideoLiked(isLiked, bvid: target.bvid, accountID: accountID)
        } catch BiliAPIError.apiRejected(let code, _)
            where code == (isLiked ? Self.alreadyLikedCode : Self.notLikedCode)
        {
            return
        } catch {
            throw Self.accountWriteError(for: error)
        }
    }

    public func setFollowing(
        _ isFollowing: Bool,
        uploader: UploaderWriteTarget,
        accountID: Int64
    ) async throws {
        do {
            try await client.setUploaderFollowing(
                isFollowing,
                mid: uploader.mid,
                accountID: accountID
            )
        } catch BiliAPIError.apiRejected(let code, _)
            where isFollowing && code == Self.alreadyFollowingCode
        {
            return
        } catch {
            throw Self.accountWriteError(for: error)
        }
    }

    public func addCoins(
        _ count: Int,
        alsoLike: Bool,
        target: VideoWriteTarget,
        accountID: Int64
    ) async throws -> Bool {
        do {
            return try await client.addVideoCoins(
                count,
                alsoLike: alsoLike,
                bvid: target.bvid,
                accountID: accountID
            )
        } catch {
            throw Self.accountWriteError(for: error)
        }
    }

    public func triple(
        target: VideoWriteTarget,
        accountID: Int64
    ) async throws -> VideoTripleOutcome {
        do {
            return try await client.tripleVideo(bvid: target.bvid, accountID: accountID)
        } catch {
            throw Self.accountWriteError(for: error)
        }
    }

    private static func accountWriteError(for error: any Error) -> any Error {
        if case BiliAPIError.apiRejected(let code, _) = error, code == declinedForClientCode {
            return AccountWriteError.declinedForClient
        }
        return AccountWriteErrorMapping.error(for: error) { code in
            switch code {
            case coinsInsufficientCode: .coinsInsufficient
            case ownVideoCode: .ownVideo
            case coinTooFrequentCode: .restricted
            case coinLimitCode: .coinLimitReached
            case missingVideoCode: .contentUnavailable
            case followLimitCode: .listFull
            default: nil
            }
        }
    }
}
