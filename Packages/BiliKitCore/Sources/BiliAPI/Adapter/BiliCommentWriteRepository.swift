import BiliApplication
import BiliModels

/// `CommentWriteRepository` 的 B 站实现：转调窗口主 API 的评论表态与发评论，并把远端失败映射为 `AccountWriteError`。
///
/// 无状态；底层 client 必须注入了账户写授权器（点赞、点踩）与 App 写授权器（发评论），即 `LiveAPIClients.main`。共同的映射在
/// `AccountWriteErrorMapping`，这里只给出评论接口的业务码，出处是接口文档（pskdje/bilibili-API-collect 镜像）与官方网页
/// 评论组件的分支，没有逐个实测。取消原样传播。
public struct BiliCommentWriteRepository: CommentWriteRepository {
    /// 评论区已关闭（12002、12052）或禁止回复（12003）。
    private static let closedCodes: Set<Int> = [12_002, 12_052, 12_003]
    /// 被 UP 主列入评论黑名单。
    private static let blockedCode = 12_035
    /// 含敏感信息（12016）、重复评论（12051）。
    private static let rejectedContentCodes: Set<Int> = [12_016, 12_051]
    /// 需要评论验证码：这里无法完成，可以在网页上发表。
    private static let verificationCode = 12_015
    /// 请求过于频繁。
    private static let tooFrequentCode = -509
    /// 没有该评论（12006）、评论主体 type 不合法（12009）。
    private static let missingCodes: Set<Int> = [12_006, 12_009]

    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func apply(_ operation: CommentReactionOperation, accountID: Int64) async throws {
        do {
            try await client.applyCommentReaction(operation, accountID: accountID)
        } catch {
            throw Self.accountWriteError(for: error)
        }
    }

    public func post(
        _ request: CommentPostRequest,
        accountID: Int64
    ) async throws -> BiliModels.Comment? {
        do {
            return try await client.postComment(request, accountID: accountID)
        } catch {
            throw Self.accountWriteError(for: error)
        }
    }

    private static func accountWriteError(for error: any Error) -> any Error {
        AccountWriteErrorMapping.error(for: error) { code in
            if closedCodes.contains(code) { return .commentsClosed }
            if code == blockedCode { return .blockedByUploader }
            if rejectedContentCodes.contains(code) { return .commentRejected }
            if code == verificationCode { return .verificationRequired }
            if code == tooFrequentCode { return .restricted }
            if missingCodes.contains(code) { return .contentUnavailable }
            return nil
        }
    }
}
