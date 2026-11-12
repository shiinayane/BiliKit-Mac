import BiliModels
import Foundation

/// 发一条弹幕的请求：落在哪个视频分 P 的哪个时刻、正文与外观。
///
/// 只由 `DanmakuPostUseCase.request(...)` 构造，正文已按 `DanmakuPostText` 规整与校验。
public struct DanmakuPostRequest: Sendable, Equatable {
    public let identity: PlaybackItemIdentity
    public let text: String
    /// 弹幕出现的播放时间（毫秒，非负）。
    public let progressMilliseconds: Int64
    public let mode: DanmakuPresentationMode
    public let colorRGB: UInt32
    public let fontSize: Double
}

/// 发出成功后服务端给的弹幕 ID（十进制字符串）；本地上屏的那一条以它为 ID，分段重新读到时据此去重。
public struct DanmakuPostReceipt: Sendable, Equatable {
    public let danmakuID: String

    public init(danmakuID: String) {
        self.danmakuID = danmakuID
    }
}

/// 一次发送的结局，由窗口的写入协调者交回输入胶囊。
public enum DanmakuPostOutcome: Sendable, Equatable {
    case posted(DanmakuPostReceipt)
    case failed(AccountWriteError)
    /// 关窗或认证会话在请求途中切换：不说明结果，服务端可能已经收下。
    case cancelled
}

/// 发送弹幕 port，实现是 BiliAPI 的 `BiliDanmakuPostRepository`，只经 `DanmakuPostUseCase` 调用。
///
/// 失败抛出 `AccountWriteError`（与其他账户写入同一套映射与复核规则），取消原样传播。写入不自动重试。
public protocol DanmakuPostRepository: Sendable {
    func post(_ request: DanmakuPostRequest, accountID: Int64) async throws -> DanmakuPostReceipt
}

/// 弹幕正文的规整与上限。
public enum DanmakuPostText {
    /// 一条弹幕最多的字符数：B 站服务端的上限，超出会被拒绝（业务码 36702）。
    public static let maximumLength = 100

    /// 去掉首尾空白；为空、超长，或含换行等控制字符、Unicode 行与段分隔符时为 nil（B 站弹幕是单行，这些字符会被服务端
    /// 拒绝、吞掉或在画面上折行）。
    public static func normalized(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximumLength,
            !text.unicodeScalars.contains(where: { breaksLine($0) })
        else { return nil }
        return text
    }

    private static func breaksLine(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: true
        default: false
        }
    }
}

/// 发送弹幕可选的外观：位置、字号与颜色各自的候选。
///
/// 字号与颜色也是账户写授权器 `dm/post` 一行允许的取值（同一来源）；位置在授权器里按 wire 值登记（BiliAuth 看不到
/// BiliAPI 的 wire 映射），改动 `modes` 时同步那一行。
/// 只开放网页播放器的普通弹幕选项：字号只有小与标准两档（网页已不提供大号），颜色取网页调色板里的 8 色。账号等级不够时
/// 服务端会拒绝彩色或顶部、底部弹幕，按普通业务拒绝带出错误码。改动候选会同时放宽或收紧授权器。
public enum DanmakuPostStyle {
    public static let modes: [DanmakuPresentationMode] = [.scrolling, .top, .bottom]
    public static let fontSizes: [Double] = [18, DanmakuEvent.standardFontSize]
    /// 白、红、橙、黄、绿、青、蓝、紫，取自网页播放器的调色板；第一项是默认色。
    public static let colors: [UInt32] = [
        0xFF_FFFF, 0xFE_0302, 0xFF_7204, 0xFF_D302, 0x00_CD00, 0x01_9899, 0x42_66BE, 0xCC_0273
    ]
}

/// 一次发送选定的外观；默认是标准字号的白色滚动弹幕，与网页播放器的默认相同。
public struct DanmakuPostAppearance: Sendable, Equatable {
    public var mode: DanmakuPresentationMode
    public var fontSize: Double
    public var colorRGB: UInt32

    public init(
        mode: DanmakuPresentationMode = .scrolling,
        fontSize: Double = DanmakuEvent.standardFontSize,
        colorRGB: UInt32 = DanmakuPostStyle.colors[0]
    ) {
        self.mode = mode
        self.fontSize = fontSize
        self.colorRGB = colorRGB
    }

    /// 三项都在 `DanmakuPostStyle` 的候选里。
    public var isSupported: Bool {
        DanmakuPostStyle.modes.contains(mode) && DanmakuPostStyle.fontSizes.contains(fontSize)
            && DanmakuPostStyle.colors.contains(colorRGB)
    }
}

/// 校验并发出一条弹幕。
public struct DanmakuPostUseCase: Sendable {
    private let repository: any DanmakuPostRepository

    public init(repository: any DanmakuPostRepository) {
        self.repository = repository
    }

    /// 规整正文并构造请求；正文不合规、外观不在候选里、identity 无效或时间为负时为 nil，不发出请求。
    public static func request(
        text: String,
        identity: PlaybackItemIdentity,
        positionSeconds: Double,
        appearance: DanmakuPostAppearance = DanmakuPostAppearance()
    ) -> DanmakuPostRequest? {
        guard let text = DanmakuPostText.normalized(text),
            BVID.isValid(identity.bvid), identity.cid > 0,
            positionSeconds.isFinite, positionSeconds >= 0,
            appearance.isSupported
        else { return nil }
        return DanmakuPostRequest(
            identity: identity,
            text: text,
            progressMilliseconds: Int64((positionSeconds * 1_000).rounded(.down)),
            mode: appearance.mode,
            colorRGB: appearance.colorRGB,
            fontSize: appearance.fontSize
        )
    }

    public func post(
        _ request: DanmakuPostRequest,
        accountID: Int64
    ) async throws -> DanmakuPostReceipt {
        guard accountID > 0 else { throw AccountWriteError.invalidRequest }
        return try await repository.post(request, accountID: accountID)
    }
}
