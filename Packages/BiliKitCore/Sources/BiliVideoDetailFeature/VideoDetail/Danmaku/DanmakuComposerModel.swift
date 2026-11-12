import BiliApplication
import BiliModels
import Observation

/// 播放器上发送弹幕的输入胶囊：是否呼出、草稿、外观选项、发送进度、失败原因与发送冷却。
///
/// 每窗口一个，由 `WindowComposition` 构造并在关窗时 `reset()`；外观选项在窗口内保留到关窗。不拥有在途的发送：请求经
/// `post` 交给窗口的写入协调者（它持有 Task、窗口内只放一条在途、关窗时取消、凭据类失败时请求复核），结局经回调交回
/// 这里。不拥有弹幕会话（发出成功后经 `DanmakuSessionControlling.presentOwnDanmaku` 交给它上屏，会话按 identity 丢弃
/// 已换掉的视频）与时间线。发送取发送那一刻时间线的视频与位置，与网页一致。写入不自动重试。
@MainActor
@Observable
public final class DanmakuComposerModel {
    /// 两次发送之间至少隔多久：B 站对带 `rnd` 的发送按 5 秒冷却（见 `BiliAccountWritePath.danmakuPost`）。
    ///
    /// 冷却内本地直接说明还要等几秒，不发注定被拒的请求；服务端仍是准绳，被拒时按受限说明。调短会多发出被拒的请求，
    /// 调长会让用户多等。
    public static let postCooldown: Duration = .seconds(5)

    /// 不能呼出、不能发出或发出失败的原因。
    public enum Failure: Equatable, Sendable {
        /// 窗口没有可写入的账户（未登录、复核中或窗口账户已过期）。
        case signInRequired
        /// 播放器此刻没有视频分 P（还在加载或已经停止）。
        case noPlayback
        /// 正文为空、超长或含换行。
        case invalidText
        /// 冷却中，还要等的整秒数（向上取整，至少 1）。
        case coolingDown(seconds: Int)
        /// 服务端或网络失败；文案由写入结果胶囊的同一套措辞给出（`AccountWriteStatusText`）。
        case write(AccountWriteReport)

        var isWriteFailure: Bool {
            if case .write = self { true } else { false }
        }
    }

    /// 胶囊此刻在做什么：编辑中、发送中（同一窗口只有这一条在途），或停在一次失败的说明上。
    public enum Phase: Equatable, Sendable {
        case editing
        case sending
        case failed(Failure)
    }

    public private(set) var isPresented = false
    public var draft = ""
    public private(set) var phase = Phase.editing
    /// 下一条弹幕的位置、字号与颜色；窗口内记住，关窗时不保留。
    public var appearance = DanmakuPostAppearance()
    /// 是否展开外观选项那一行。
    public var showsOptions = false
    /// 每次呼出递增；视图据此把焦点交给输入框（已呼出时再按一次也重新聚焦）。
    public private(set) var presentationID: UInt64 = 0
    /// 呼出被拒（未登录或没有在播的视频）时调用，参数是原因。
    ///
    /// 由播放器浮层在拿到胶囊时设置，在播放器顶部提示；回车、动作菜单与工具栏按钮都只调用 `present()`，提示因此只有
    /// 这一处。
    @ObservationIgnored public var onPresentationRefused: @MainActor (Failure) -> Void = { _ in }
    /// 发出成功时调用，参数是结果说明（`AccountWriteStatusText` 的措辞）。
    ///
    /// 由播放器浮层设置，在顶部提示并通告：弹幕关着、这种位置被隐藏或车道已满时画面上看不到这一条，读屏用户也看不到。
    @ObservationIgnored public var onPosted: @MainActor (AccountWriteReport) -> Void = { _ in }

    @ObservationIgnored private let presentation: any DanmakuSessionControlling
    @ObservationIgnored private let timeline: @MainActor () -> PlaybackTimelineSnapshot
    @ObservationIgnored private let canPost: @MainActor () -> Bool
    @ObservationIgnored private let post:
        @MainActor (
            DanmakuPostRequest, @escaping @MainActor (DanmakuPostOutcome) -> Void
        ) -> Bool
    /// 上一条发出成功的时刻；冷却据此计算。
    @ObservationIgnored private var lastPostedAt: ContinuousClock.Instant?

    /// `timeline` 读窗口播放器此刻的时间线；`canPost` 是窗口此刻能否写入（写入协调者的门槛）；`post` 把请求交给写入
    /// 协调者，返回是否发出，结局经回调交回。
    public init(
        presentation: any DanmakuSessionControlling,
        timeline: @escaping @MainActor () -> PlaybackTimelineSnapshot,
        canPost: @escaping @MainActor () -> Bool,
        post:
            @escaping @MainActor (
                DanmakuPostRequest, @escaping @MainActor (DanmakuPostOutcome) -> Void
            ) -> Bool
    ) {
        self.presentation = presentation
        self.timeline = timeline
        self.canPost = canPost
        self.post = post
    }

    public var isSending: Bool { phase == .sending }

    /// 此刻能否呼出：窗口能写入且播放器有视频分 P。
    ///
    /// 动作菜单据此决定可用状态，`present()` 用同一判断。
    public var canPresent: Bool {
        refusal == nil
    }

    /// 呼出输入胶囊并把焦点交给输入框；未登录或没有在播的视频时不呼出，改经 `onPresentationRefused` 提示。
    ///
    /// 本地的失败说明（未登录、冷却等）清掉；收起期间才到达的发送失败保留，呼出时还能看到原因。草稿与外观保留。
    public func present() {
        if let refusal { return onPresentationRefused(refusal) }
        isPresented = true
        presentationID &+= 1
        if case .failed(let failure) = phase, !failure.isWriteFailure { phase = .editing }
    }

    /// 收起输入胶囊；草稿保留到下次呼出，已经看过的失败说明清掉。
    ///
    /// 在途的发送照常完成：请求可能已经到达服务端，成功时仍在画面上补出这一条并提示，失败时说明留到下次呼出。由视频页在
    /// 换视频与离开播放页时调用，免得旧视频的草稿发到新视频上。
    public func dismiss() {
        isPresented = false
        showsOptions = false
        if case .failed = phase { phase = .editing }
    }

    private var refusal: Failure? {
        guard canPost() else { return .signInRequired }
        guard timeline().identity != nil else { return .noPlayback }
        return nil
    }

    /// 发出草稿；成功时本地立即上屏、清空草稿并收起胶囊，失败时停在胶囊里说明原因、草稿保留。
    public func send() {
        // 收起后淡出期间输入框可能还在，回车不应发出看不见的草稿。
        guard isPresented, phase != .sending else { return }
        guard canPost() else {
            phase = .failed(.signInRequired)
            return
        }
        if let lastPostedAt {
            let remaining = Self.postCooldown - (ContinuousClock.now - lastPostedAt)
            if remaining > .zero {
                phase = .failed(.coolingDown(seconds: Self.wholeSeconds(rounding: remaining)))
                return
            }
        }
        let snapshot = timeline()
        guard let identity = snapshot.identity else {
            phase = .failed(.noPlayback)
            return
        }
        guard
            let request = DanmakuPostUseCase.request(
                text: draft,
                identity: identity,
                positionSeconds: snapshot.positionSeconds,
                appearance: appearance
            )
        else {
            phase = .failed(.invalidText)
            return
        }
        let sentDraft = draft
        let issued = post(request) { [weak self] outcome in
            self?.finish(request, sentDraft: sentDraft, outcome: outcome)
        }
        // 协调者没有发出：门槛在这一刻变了（另一条在途时 `phase` 已是 `.sending`，到不了这里）。
        phase = issued ? .sending : .failed(.signInRequired)
    }

    /// 关窗时调用：收起并清空草稿与外观；在途的发送由写入协调者在关窗时取消。
    public func reset() {
        isPresented = false
        showsOptions = false
        draft = ""
        phase = .editing
        appearance = DanmakuPostAppearance()
        lastPostedAt = nil
    }

    private func finish(
        _ request: DanmakuPostRequest,
        sentDraft: String,
        outcome: DanmakuPostOutcome
    ) {
        switch outcome {
        case .posted(let receipt):
            lastPostedAt = .now
            presentation.presentOwnDanmaku(
                Self.ownEvent(for: request, receipt: receipt),
                for: request.identity
            )
            // 发送期间改过的草稿不清，免得吞掉新写的字。
            if draft == sentDraft { draft = "" }
            phase = .editing
            isPresented = false
            showsOptions = false
            if let target = VideoWriteTarget(bvid: request.identity.bvid) {
                onPosted(AccountWriteReport(change: .danmakuPosted(target), failure: nil))
            }
        case .failed(let error):
            guard let target = VideoWriteTarget(bvid: request.identity.bvid) else {
                phase = .editing
                return
            }
            phase = .failed(
                .write(AccountWriteReport(change: .danmakuPosted(target), failure: error))
            )
        case .cancelled:
            phase = .editing
        }
    }

    private static func wholeSeconds(rounding duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return max(1, Int(seconds) + (attoseconds > 0 ? 1 : 0))
    }

    /// 本地上屏的那一条：外观与发出的相同，ID 是服务端给的弹幕 ID。
    private static func ownEvent(
        for request: DanmakuPostRequest,
        receipt: DanmakuPostReceipt
    ) -> DanmakuEvent {
        DanmakuEvent(
            id: receipt.danmakuID,
            timeSeconds: Double(request.progressMilliseconds) / 1_000,
            mode: request.mode,
            text: request.text,
            fontSize: request.fontSize,
            colorRGB: request.colorRGB,
            colorStyle: .solid,
            weight: 0,
            isHighLike: false,
            isUploader: false,
            isOwn: true
        )
    }
}
