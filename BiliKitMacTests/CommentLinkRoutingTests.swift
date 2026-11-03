import BiliAPI
import BiliVideoDetailFeature
import Foundation
import Testing

@testable import BiliKit
@testable import BiliModels

/// 评论链接目标翻译成 App 路由：视频链接带上分 P 与起播秒数，短链给出解析闭包并以原地址兜底。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CommentLinkRoutingTests {
    private let routing = CommentLinkRouting(
        linkResolver: BiliCommentLinkResolver(),
        shortLinkResolver: BiliShortLinkResolver()
    )

    @Test
    func videoLinksBecomePlaybackIntentsWithTheirPageAndStart() {
        guard
            case .playback(let intent) = routing.route(
                for: .video(bvid: "BV1xx411c7mD", page: 2, startSeconds: 30)
            )
        else {
            Issue.record("视频链接应在应用内播放")
            return
        }
        #expect(
            intent
                == PlaybackSelectionIntent(
                    bvid: "BV1xx411c7mD",
                    preferredPageNumber: 2,
                    preferredStartSeconds: 30
                )
        )
    }

    /// 短链先解析再打开，解析不出时回退到原地址；不是 b23.tv 短码形状的地址解析时不发请求。
    @Test
    func shortLinksResolveBeforeOpening() async throws {
        let url = try #require(URL(string: "https://example.invalid/short"))
        guard
            case .shortLink(let resolve, let webFallback) = routing.route(
                for: .shortLink(CommentExternalLinkReference(remoteURL: url))
            )
        else {
            Issue.record("短链应先解析再打开")
            return
        }
        #expect(webFallback == url)
        #expect(await resolve() == nil)
    }
}

/// 短链解析只打开最后一次点击的结果：新的点击或取消之后，在途解析即使返回了路由也不再打开。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CommentShortLinkResolutionTests {
    /// 新的点击取消上一个在途解析，只打开最后一次的结果。
    ///
    /// 被取消的解析在取消后仍返回路由；等它的任务结束（捕获的闭包被释放）再断言，证明靠的是取消后的
    /// 检查，而不是任务还没来得及运行。
    @Test
    func aNewClickCancelsTheResolutionInFlight() async throws {
        let first = try #require(URL(string: "https://www.bilibili.com/read/cv1"))
        let second = try #require(URL(string: "https://www.bilibili.com/read/cv2"))
        let resolution = CommentShortLinkResolution()
        let (released, release) = AsyncStream<Void>.makeStream()
        var opened: [URL?] = []

        do {
            let token = ReleaseSignal(release)
            resolution.start(
                { await Self.routeAfterCancellation(first) },
                open: { route in
                    withExtendedLifetime(token) { opened.append(Self.webURL(route)) }
                }
            )
        }
        let secondOpened = await withCheckedContinuation {
            (continuation: CheckedContinuation<URL?, Never>) in
            resolution.start({ .web(second) }) { route in
                continuation.resume(returning: Self.webURL(route))
            }
        }
        var iterator = released.makeAsyncIterator()
        await iterator.next()

        #expect(secondOpened == second)
        #expect(opened.isEmpty)
    }

    /// 换视频或关窗时取消：在途解析即使返回了路由也不再打开。
    @Test
    func cancelStopsTheResolutionInFlight() async throws {
        let url = try #require(URL(string: "https://www.bilibili.com/read/cv1"))
        let resolution = CommentShortLinkResolution()
        let (released, release) = AsyncStream<Void>.makeStream()
        var openCount = 0

        do {
            let token = ReleaseSignal(release)
            resolution.start(
                { await Self.routeAfterCancellation(url) },
                open: { _ in withExtendedLifetime(token) { openCount += 1 } }
            )
        }
        resolution.cancel()
        var iterator = released.makeAsyncIterator()
        await iterator.next()

        #expect(openCount == 0)
    }

    /// 挂起到任务被取消，再返回一个非空路由。
    private nonisolated static func routeAfterCancellation(_ url: URL) async -> CommentLinkRoute? {
        let (never, keepAlive) = AsyncStream<Void>.makeStream()
        for await _ in never {}
        keepAlive.finish()
        return .web(url)
    }

    private static func webURL(_ route: CommentLinkRoute?) -> URL? {
        guard case .web(let url) = route else { return nil }
        return url
    }
}

/// 被释放时发出信号：用来等到一个任务结束、它捕获的闭包随之释放。
private final class ReleaseSignal: Sendable {
    private let continuation: AsyncStream<Void>.Continuation

    init(_ continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }

    deinit {
        continuation.yield()
    }
}
