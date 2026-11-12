import BiliApplication
import BiliModels
import BiliVideoDetailFeature
import Testing

/// 弹幕输入胶囊：只在窗口能写入且有在播的视频时呼出，否则交给浮层提示；发送取发送那一刻的播放位置与选定外观，
/// 同时只有一条在途；成功后立即以“自己发的”上屏、清空草稿、收起并交给浮层提示，失败时停在胶囊里说明原因、草稿保留，
/// 收起期间才到达的失败在再次呼出时仍看得到；成功后冷却内不再发出请求。
@MainActor
@Suite
struct DanmakuComposerModelTests {
    @Test
    func refusesToOpenWithoutAWritableAccountOrPlayback() {
        let harness = ComposerHarness()
        harness.canPost = false
        harness.snapshot = .idle
        var refusals: [DanmakuComposerModel.Failure] = []
        harness.model.onPresentationRefused = { refusals.append($0) }

        harness.model.present()
        harness.canPost = true
        harness.model.present()
        #expect(!harness.model.isPresented)
        #expect(refusals == [.signInRequired, .noPlayback])

        harness.snapshot = ComposerHarness.playing(at: 12)
        harness.model.present()
        #expect(harness.model.isPresented)
    }

    @Test
    func postedDanmakuAppearsAsOwnAndClosesTheComposer() throws {
        let harness = ComposerHarness()
        let model = harness.model
        var posted: [AccountWriteReport] = []
        model.onPosted = { posted.append($0) }
        model.present()
        model.draft = "  好+1  "
        model.appearance = DanmakuPostAppearance(mode: .top, fontSize: 18, colorRGB: 0xFE_0302)

        harness.snapshot = ComposerHarness.playing(at: 12.3456)
        model.send()
        model.send()
        #expect(model.isSending)
        #expect(harness.requests.count == 1)
        let request = try #require(harness.requests.first)
        #expect(request.text == "好+1")
        #expect(request.progressMilliseconds == 12_345)
        #expect(request.mode == .top && request.fontSize == 18 && request.colorRGB == 0xFE_0302)

        harness.complete(.posted(DanmakuPostReceipt(danmakuID: "42")))
        let shown = try #require(harness.presentation.ownDanmaku.first)
        #expect(shown.identity == ComposerHarness.identity)
        #expect(shown.event.id == "42" && shown.event.isOwn && shown.event.mode == .top)
        #expect(model.draft.isEmpty)
        #expect(!model.isPresented)
        #expect(posted.map(\.failure) == [nil])

        // 冷却内再发：本地说明还要等，不发请求。
        model.present()
        model.draft = "再来"
        model.send()
        #expect(harness.requests.count == 1)
        guard case .failed(.coolingDown(let seconds)) = model.phase else {
            Issue.record("冷却内应说明还要等几秒，实际 \(model.phase)")
            return
        }
        #expect((1...5).contains(seconds))
    }

    @Test
    func failedPostKeepsTheDraftAndExplainsWhy() throws {
        let harness = ComposerHarness()
        let model = harness.model
        model.present()
        model.draft = "好"
        model.send()
        // 发送中收起：失败在收起期间到达，再次呼出时仍要看到原因。
        model.dismiss()
        harness.complete(.failed(.restricted))
        model.present()

        let target = try #require(VideoWriteTarget(bvid: ComposerHarness.identity.bvid))
        #expect(
            model.phase
                == .failed(
                    .write(AccountWriteReport(change: .danmakuPosted(target), failure: .restricted))
                )
        )
        #expect(model.draft == "好")
        #expect(model.isPresented)
        #expect(harness.presentation.ownDanmaku.isEmpty)
    }
}

/// 胶囊与它的依赖：可改的写入门槛与时间线，记录交给写入协调者的请求，测试经 `complete` 交回结局。
@MainActor
private final class ComposerHarness {
    static let identity = PlaybackItemIdentity(bvid: "BV1xx411c7mD", cid: 1_176_840)

    let presentation = RecordingDanmakuPresentation()
    var canPost = true
    var snapshot = playing(at: 10)
    private(set) var requests: [DanmakuPostRequest] = []
    private var completions: [@MainActor (DanmakuPostOutcome) -> Void] = []
    private(set) lazy var model = DanmakuComposerModel(
        presentation: presentation,
        timeline: { [unowned self] in self.snapshot },
        canPost: { [unowned self] in self.canPost },
        post: { [unowned self] request, completion in
            self.requests.append(request)
            self.completions.append(completion)
            return true
        }
    )

    /// 交回最早一条还没结束的发送的结局。
    func complete(_ outcome: DanmakuPostOutcome) {
        guard !completions.isEmpty else {
            Issue.record("没有在途的发送")
            return
        }
        completions.removeFirst()(outcome)
    }

    static func playing(at seconds: Double) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: seconds,
            durationSeconds: 60,
            rate: 1,
            state: .playing,
            discontinuityGeneration: 0
        )
    }
}
