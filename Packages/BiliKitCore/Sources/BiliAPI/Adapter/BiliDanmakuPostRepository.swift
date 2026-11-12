import BiliApplication
import Foundation

/// `DanmakuPostRepository` 的 B 站实现：转调窗口主 API 的弹幕发送，并把远端失败映射为 `AccountWriteError`。
///
/// 无状态；底层 client 必须注入了账户写授权器（`LiveAPIClients.main`），否则一律按“需要登录”失败。取消原样传播。
/// 共同的映射在 `AccountWriteErrorMapping`，这里只给出弹幕接口的业务码；其余业务码按普通拒绝带出错误码。
public struct BiliDanmakuPostRepository: DanmakuPostRepository {
    /// 发送太频繁（冷却中）。
    ///
    /// 业务码出处是第三方客户端与接口文档的交叉核实，尚未逐个实测。
    private static let tooFrequentCode = 36_703
    /// 稿件不存在或还没过审，不能发弹幕。
    private static let unavailableVideoCodes: Set<Int> = [36_704]

    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func post(
        _ request: DanmakuPostRequest,
        accountID: Int64
    ) async throws -> DanmakuPostReceipt {
        do {
            let danmakuID = try await client.postDanmaku(request, accountID: accountID)
            return DanmakuPostReceipt(danmakuID: danmakuID)
        } catch {
            throw AccountWriteErrorMapping.error(for: error) { code in
                if code == Self.tooFrequentCode { return .restricted }
                if Self.unavailableVideoCodes.contains(code) { return .contentUnavailable }
                return nil
            }
        }
    }
}
