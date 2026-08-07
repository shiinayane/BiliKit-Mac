import BiliApplication
import Observation

public enum GuestVideoFailure: Sendable, Equatable {
    case content(GuestApplicationError)
    case playback
}

public enum GuestVideoState: Sendable, Equatable {
    case idle
    case loading(bvid: String)
    case preparingPlayback(GuestVideoContext)
    case ready(GuestVideoContext)
    case failed(bvid: String, failure: GuestVideoFailure)
}

@MainActor
@Observable
/// 拥有单个视频准备意图，并把内容准备与播放器安装串成同一 generation。
///
/// 新视频、重试或 reset 都使旧任务失效；旧任务即使忽略取消，也不能覆盖当前状态。
public final class GuestVideoViewModel {
    public private(set) var state: GuestVideoState = .idle
    /// 供播放主区与上下文 Sidebar 共享的最近有效详情。
    ///
    /// 新视频加载或失败期间保留旧值，使同一个播放 surface 不因短暂状态拆除；取得新
    /// context 后原子替换，最终 reset 或当前请求取消回到 idle 时清空。
    public private(set) var presentedContext: GuestVideoContext?

    @ObservationIgnored private let useCase: GuestVideoUseCase
    @ObservationIgnored private let playback: any PlaybackControlling
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    public init(
        useCase: GuestVideoUseCase,
        playback: any PlaybackControlling
    ) {
        self.useCase = useCase
        self.playback = playback
    }

    /// 取代当前播放意图；已有非 idle 会话会先停止，避免两个 bridge/server 并存。
    public func loadVideo(_ bvid: String) {
        generation += 1
        let currentGeneration = generation
        loadTask?.cancel()
        if state != .idle {
            playback.stop()
        }
        state = .loading(bvid: bvid)
        loadTask = Task { [weak self] in
            await self?.performLoad(
                bvid: bvid,
                generation: currentGeneration
            )
        }
    }

    /// 取消内容准备并停止播放 adapter，作为离开播放目的地的最终清理边界。
    public func reset() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        presentedContext = nil
        state = .idle
        playback.stop()
    }

    public func waitForCurrentTask() async {
        await loadTask?.value
    }

    func taskSnapshotForTesting() -> Task<Void, Never>? {
        loadTask
    }

    private func performLoad(
        bvid: String,
        generation currentGeneration: Int
    ) async {
        do {
            let context = try await useCase.prepareVideo(bvid: bvid)
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }

            presentedContext = context
            state = .preparingPlayback(context)
            try await playback.load(
                context.playback,
                identity: PlaybackItemIdentity(
                    bvid: context.detail.bvid,
                    cid: context.selectedPage.cid
                )
            )
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }
            state = .ready(context)
        } catch is CancellationError {
            guard generation == currentGeneration else { return }
            presentedContext = nil
            state = .idle
        } catch let error as GuestApplicationError {
            guard generation == currentGeneration else { return }
            state = .failed(bvid: bvid, failure: .content(error))
        } catch {
            guard generation == currentGeneration else { return }
            state = .failed(bvid: bvid, failure: .playback)
        }

        if generation == currentGeneration {
            loadTask = nil
        }
    }
}
