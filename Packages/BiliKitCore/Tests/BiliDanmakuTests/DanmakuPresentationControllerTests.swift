import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定呈现控制器的契约：时刻一律是时钟层的显示时间 D，快照只是检查节拍，时钟写入不等快照也会
/// 重新检查，读不到 D 时什么都不挂；画面在分段布局完成后按 D 出现，看得见的集合与布局表在 D 时刻一致；
/// D 离开上次对齐后的一个步长（含回跳）就对齐，步长内什么都不做，步长加一个快照周期短于前瞻；跳到纹理已
/// 缓存的地方在一次调用里整屏换成那一刻的样子；连续拖动时已就绪的纹理每一步都挂上、不被扣留，拖进未缓存
/// 区域、分段陆续到达时也一样，停下后补齐落点（落点分段未到时不留旧画面）；改设置后新表落地的同一次调用
/// 里在屏的全部换到新车道，与拖动交错时也一样，之后每就绪一条就出现；关闭弹幕清屏、打开恢复；换 backing
/// scale 时在屏的弹幕逐条原位换纹理，新表落地后换到新车道，新纹理被拒的也换车道，在某个 scale 下纹理超限的
/// 长弹幕换到放得下它的 scale 后重新出现；换视频清屏；换 item 只接受当前 owner，清屏后
/// 直到新 item 的快照与新时钟纪元的 D 都有了才按原布局表挂回；切视频时旧 item 解绑后、新 item 有时间之前
/// 什么都不挂；旧 surface owner 的操作与唤醒无效；窗口尺寸变化不重排、立即按新取景框增删，屏幕尺寸变化
/// 整张重排。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DanmakuPresentationControllerTests {
    private let identity = PlaybackItemIdentity(bvid: "BV1Controller", cid: 1)
    /// 时钟层发布的 D，每个测试一份；`move` 让它与快照位置一致，分歧测试单独让两者分开。
    private let clock = ManualDisplayClock()

    @Test
    func screenAppearsOnceTheSegmentIsLaidOut() async {
        let (controller, backend) = makeController()
        move(controller, to: 30, generation: 1, state: .paused)
        controller.setSegments([1: events()], for: identity)

        await backend.waitUntil { !backend.installed.isEmpty }
        #expect(backend.installedEventIDs == expectedIDs(at: 30, in: controller))
        expectVisibility(in: controller, backend, at: 30)
    }

    @Test
    func farJumpWithCachedTexturesShowsTheWholeScreenInOneCall() async {
        let (controller, backend) = await laidOutController(at: 30)
        let clearCount = backend.clearCount

        for position in [120.0, 160, 200] {
            move(controller, to: position, generation: 1)
            #expect(backend.installedEventIDs == expectedIDs(at: position, in: controller))
            expectVisibility(in: controller, backend, at: position)
        }
        #expect(backend.clearCount == clearCount)
    }

    @Test
    func draggingKeepsInstallingReadyTextures() async {
        let (controller, backend) = await laidOutController(at: 30)
        backend.delaysPreparation = true

        let steps = (0..<13).map { 120 + Double($0) * Self.dragStep }
        for position in steps {
            move(controller, to: position, generation: 1)
            expectNothingWithheld(in: controller, backend, at: position)
            backend.completePreparations(backend.pendingPreparationCount / 2)
            expectNothingWithheld(in: controller, backend, at: position)
        }
        backend.completePreparations()

        expectVisibility(in: controller, backend, at: steps[steps.count - 1])
    }

    /// 落点分段还没到：按新时刻对齐（旧时刻的弹幕全部移走），分段到达后整屏挂上。
    @Test
    func draggingIntoUncachedSegmentsKeepsFollowing() async {
        let (controller, backend) = await laidOutController(at: 30)
        backend.delaysPreparation = true
        let second = denseEvents(segment: 2, count: 900, seed: 151)
        let third = denseEvents(segment: 3, count: 900, seed: 152)
        func step(to position: Double) {
            move(controller, to: position, generation: 1)
            expectNothingWithheld(in: controller, backend, at: position)
            backend.completePreparations(backend.pendingPreparationCount / 2)
            expectNothingWithheld(in: controller, backend, at: position)
            #expect(
                !visibleEventIDs(on: backend, at: position, viewport: controller.viewport).isEmpty
            )
        }

        for (segments, start) in [
            ([1: events(), 2: second], 400.0), ([1: events(), 2: second, 3: third], 730)
        ] {
            move(controller, to: start, generation: 1)
            #expect(backend.installed.isEmpty)
            let waiting = backend.pendingPreparationCount
            controller.setSegments(segments, for: identity)
            await backend.waitUntil { backend.pendingPreparationCount > waiting }
            backend.completePreparations(backend.pendingPreparationCount / 2)
            for count in 1...3 {
                step(to: start + Double(count) * Self.dragStep)
            }
        }
        backend.completePreparations()

        expectVisibility(in: controller, backend, at: 730 + 3 * Self.dragStep)
    }

    @Test
    func farSeekShowsNothingStaleUntilItsSegmentArrives() async {
        let (controller, backend) = await laidOutController(at: 30)

        move(controller, to: 1_000, generation: 2, state: .paused)
        #expect(backend.installed.isEmpty)

        let far = (0..<200).map { danmakuEvent(id: "far-\($0)", time: 990 + Double($0) * 0.1) }
        controller.setSegments([1: events(), 3: far], for: identity)
        await backend.waitUntil { !backend.installed.isEmpty }
        #expect(backend.installedEventIDs == expectedIDs(at: 1_000, in: controller))
        #expect(backend.installedEventIDs.allSatisfy { $0.hasPrefix("far-") })
        expectVisibility(in: controller, backend, at: 1_000)
    }

    /// 步长加一个快照周期短于前瞻：按步长推进时，即将进场的弹幕在进场前已请求过纹理。
    ///
    /// 这条不等式不含栅格化余量：步长贴着前瞻（例如 1.9 秒）它仍成立，余下的准备时间取决于密度，单元测试量不出。
    /// 「越过步长就对齐、就绪即可见」的真正防线是按 `dragStep` 拖动的那几个测试。
    @Test
    func strideAndOneCheckIntervalFitInsideTheLookahead() {
        let snapshotInterval = 1 / Double(PlaybackTimelineSnapshot.periodicSnapshotsPerMediaSecond)
        #expect(
            DanmakuPresentationController.reconcileStride + snapshotInterval
                < DanmakuMaterializer.lookaheadSeconds
        )
    }

    /// 步长内的跳变（含 timebase 向前重锚、恢复播放时的前跳）什么都不做：屏上已挂的就是此刻应有的。
    @Test
    func jumpWithinTheStrideDoesNothing() async {
        let (controller, backend) = await laidOutController(at: 30)
        backend.delaysPreparation = true
        let before = backend.installed
        let removed = backend.removedHistory.count
        let clearCount = backend.clearCount

        move(controller, to: 30.9, generation: 2)
        #expect(backend.installed == before)
        #expect(backend.removedHistory.count == removed)
        #expect(backend.pendingPreparationCount == 0)
        #expect(backend.clearCount == clearCount)
    }

    @Test
    func jumpingBackReconcilesEvenBySmallAmounts() async throws {
        let (controller, backend) = await laidOutController(at: 30)
        let target = 29.7
        try #require(expectedIDs(at: target, in: controller) != backend.installedEventIDs)

        move(controller, to: target, generation: 1)
        #expect(backend.installedEventIDs == expectedIDs(at: target, in: controller))
        expectVisibility(in: controller, backend, at: target)
    }

    /// 暂停中 seek：时钟层跳到新位置后不等快照，写入通知就按新的 D 整屏对齐；别的 owner 的通知无效。
    @Test
    func clockJumpReconcilesWithoutASnapshot() async {
        let owner = UUID()
        let (controller, backend) = await laidOutController(at: 30, surfaceOwner: owner)
        let before = backend.installed

        clock.time = 120
        controller.displayClockDidChange(ownerID: UUID())
        #expect(backend.installed == before)

        controller.displayClockDidChange(ownerID: owner)
        #expect(backend.installedEventIDs == expectedIDs(at: 120, in: controller))
        expectVisibility(in: controller, backend, at: 120)
    }

    /// 回归护栏：快照回跳或领先（seek 起播、未缓冲拖动、4x 跳变风暴）而 D 不动时，屏上集合一条不变，
    /// 看得见的仍是布局表在 D 时刻的样子。
    @Test(arguments: [29.7, 25.0, 31.6, 75.0])
    func snapshotDivergingFromTheClockKeepsTheScreen(snapshotPosition: Double) async throws {
        let (controller, backend) = await laidOutController(at: 30)
        try #require(expectedIDs(at: snapshotPosition, in: controller) != backend.installedEventIDs)
        let before = backend.installed
        let removed = backend.removedHistory.count

        controller.apply(snapshot(identity: identity, position: snapshotPosition, generation: 2))

        #expect(backend.installed == before)
        #expect(backend.removedHistory.count == removed)
        expectVisibility(in: controller, backend, at: 30)
    }

    /// 切视频时，新 item 有时间之前什么都不挂。
    ///
    /// 旧 item 解绑后时钟读不到 D（没有 item 就没有时间）。新视频的快照与分段在新 item 有时间之前到达，
    /// 不会按旧视频的时刻冻结在黑屏上；新 item 的 D 到了才按它的时刻挂上。
    @Test
    func switchingVideosShowsNothingUntilTheNewItemHasATime() async {
        let owner = UUID()
        let (controller, backend) = await laidOutController(at: 300, surfaceOwner: owner)
        let next = PlaybackItemIdentity(bvid: "BV1NextVideo", cid: 2)

        controller.playerItemWillChange(ownerID: owner)
        clock.time = nil
        controller.apply(snapshot(identity: next, position: 0, generation: 1, state: .loading))
        controller.setSegments([1: events()], for: next)
        while controller.layoutTable.isEmpty {
            await Task.yield()
        }
        #expect(backend.installed.isEmpty)

        clock.time = 0
        controller.displayClockDidChange(ownerID: owner)
        #expect(!backend.installed.isEmpty)
        #expect(backend.installedEventIDs == expectedIDs(at: 0, in: controller))
    }

    /// 改设置后紧接着拖动、纹理只陆续完成一部分：新表落地之后的每一步屏上都只出自新布局，就绪的都看得见。
    @Test
    func settingsChangeWhileDraggingReachesTheNewLayoutMidDrag() async {
        let (controller, backend) = await laidOutController(at: 30)
        let oldTable = placementsByEventID(controller.layoutTable)
        backend.delaysPreparation = true
        controller.setSpeedLevel(.one)
        await backend.waitUntil { backend.pendingPreparationCount > 0 }
        let newTable = placementsByEventID(controller.layoutTable)
        #expect(newTable != oldTable)

        let steps = (1...12).map { 30 + Double($0) * Self.dragStep }
        #expect(backend.installed.allSatisfy { newTable[$0.key] == $0.value })
        for position in steps {
            move(controller, to: position, generation: 1)
            backend.completePreparations((backend.pendingPreparationCount + 1) / 2)
            #expect(!backend.installed.isEmpty)
            #expect(backend.installed.allSatisfy { newTable[$0.key] == $0.value })
            expectNothingWithheld(in: controller, backend, at: position)
        }
    }

    @Test
    func disablingClearsAndEnablingRestoresTheCurrentTime() async {
        let (controller, backend) = await laidOutController(at: 30)

        controller.setEnabled(false)
        #expect(backend.installed.isEmpty)
        move(controller, to: 45, generation: 1, state: .paused)
        #expect(backend.installed.isEmpty)

        controller.setEnabled(true)
        #expect(backend.installedEventIDs == expectedIDs(at: 45, in: controller))
        expectVisibility(in: controller, backend, at: 45)
    }

    /// 改设置：新表落地的同一次调用里在屏的全部换到新表的车道，之后每就绪一条就出现；任何时刻屏上都只出自
    /// 新表。
    @Test
    func settingsChangeReplacesTheScreenWithTheNewLayout() async {
        let (controller, backend) = await laidOutController(at: 30)
        let oldTable = controller.layoutTable.mapValues(\.placements)
        backend.delaysPreparation = true

        controller.setSpeedLevel(.one)
        await backend.waitUntil { controller.layoutTable.mapValues(\.placements) != oldTable }
        let current = placementsByEventID(controller.layoutTable)
        func expectOnlyTheNewLanes() {
            #expect(backend.installed.allSatisfy { current[$0.key] == $0.value })
            expectNothingWithheld(in: controller, backend, at: 30)
        }
        #expect(!backend.installed.isEmpty)
        expectOnlyTheNewLanes()
        while backend.pendingPreparationCount > 0 {
            backend.completePreparations(1)
            expectOnlyTheNewLanes()
        }
        expectVisibility(in: controller, backend, at: 30)
    }

    @Test
    func newIdentityClearsTheScreen() async {
        let (controller, backend) = await laidOutController(at: 30)

        controller.apply(
            snapshot(
                identity: PlaybackItemIdentity(bvid: "BV1Other", cid: 2),
                position: 0,
                generation: 1
            )
        )
        #expect(backend.installed.isEmpty)
        controller.setSegments([1: events()], for: identity)
        #expect(controller.layoutTable.isEmpty)
    }

    /// 换 item 前只有当前 surface owner 能清屏；别的 owner 调用无效，画面不动。
    @Test
    func playerItemChangeFromAnotherOwnerIsIgnored() async {
        let owner = UUID()
        let (controller, backend) = await laidOutController(at: 30, surfaceOwner: owner)
        let before = backend.installed
        let clearCount = backend.clearCount

        controller.playerItemWillChange(ownerID: UUID())
        #expect(backend.installed == before)
        #expect(backend.clearCount == clearCount)
    }

    /// 同一视频换线路或清晰度：换 item 时清屏、保留布局表；时钟换绑后新纪元还没写入（D 读不到）时 resize
    /// 不挂回；新 item 的快照与新纪元的 D 只到一个都不挂，两个都到了（不论先后）才按原布局表整屏挂回。
    @Test(arguments: [true, false])
    func playerItemChangeWaitsForTheNewSnapshotAndTheNewClockEpoch(snapshotFirst: Bool) async {
        let owner = UUID()
        let (controller, backend) = await laidOutController(at: 30, surfaceOwner: owner)
        let before = backend.installed

        controller.playerItemWillChange(ownerID: owner)
        clock.time = nil
        #expect(backend.installed.isEmpty)
        let window = Size(width: 800, height: 360)
        resize(controller, owner: owner, window: window, screen: window)
        #expect(backend.installed.isEmpty)

        if snapshotFirst {
            controller.apply(pausedSnapshot(at: 30))
            #expect(backend.installed.isEmpty)
            clock.time = 30
            controller.displayClockDidChange(ownerID: owner)
        } else {
            clock.time = 30
            controller.displayClockDidChange(ownerID: owner)
            #expect(backend.installed.isEmpty)
            controller.apply(pausedSnapshot(at: 30))
        }
        #expect(backend.installed == before)
    }

    @Test
    func staleSurfaceOwnerCannotResizeDetachOrWake() async {
        let (controller, backend) = makeController()
        let first = UUID()
        let second = UUID()
        controller.attachSurface(ownerID: first, clock: clock)
        controller.attachSurface(ownerID: second, clock: clock)

        let sizesBefore = backend.surfaceSizes.count
        controller.updateSurface(
            width: 10,
            height: 10,
            screenWidth: 10,
            screenHeight: 10,
            backingScale: 2,
            ownerID: first
        )
        #expect(backend.surfaceSizes.count == sizesBefore)
        #expect(!controller.detachSurface(ownerID: first))
        #expect(controller.detachSurface(ownerID: second))
        #expect(backend.stopCount == 0)
    }

    /// 窗口缩小与放大都不重排：布局表与一开始就用小窗口时相同；增删当场按新取景框完成，不清屏；
    /// 放大后的画面与一直是大窗口时相同，新露出的、正在飞的弹幕按原 placement 挂上。
    @Test
    func resizingKeepsTheTableAndReconcilesTheVisibleSetAtOnce() async {
        let screen = Size(width: 1_200, height: 720)
        let owner = UUID()
        let (controller, backend) = await laidOutController(
            at: 30,
            surfaceOwner: owner,
            window: screen,
            screen: screen
        )
        let table = controller.layoutTable
        let fullScreen = backend.installed
        let clearCount = backend.clearCount

        resize(controller, owner: owner, window: Size(width: 600, height: 300), screen: screen)
        #expect(controller.layoutTable.mapValues(\.placements) == table.mapValues(\.placements))
        #expect(backend.installedEventIDs == expectedIDs(at: 30, in: controller))
        #expect(backend.installed.count < fullScreen.count)
        #expect(backend.clearCount == clearCount)
        expectVisibility(in: controller, backend, at: 30)

        let (small, _) = await laidOutController(
            at: 30,
            window: Size(width: 600, height: 300),
            screen: screen
        )
        #expect(small.layoutTable.mapValues(\.placements) == table.mapValues(\.placements))

        resize(controller, owner: owner, window: screen, screen: screen)
        #expect(backend.installed == fullScreen)
        #expect(backend.clearCount == clearCount)
    }

    /// 换到尺寸不同的屏幕：按新的规划尺寸整张重排，整屏换成新布局。
    @Test
    func screenChangeRelaysOutTheWholeTable() async {
        let owner = UUID()
        let window = Size(width: 800, height: 360)
        let (controller, backend) = await laidOutController(
            at: 30,
            surfaceOwner: owner,
            window: window,
            screen: window
        )

        resize(controller, owner: owner, window: window, screen: Self.largerScreen)
        await backend.waitUntil {
            !backend.installed.isEmpty
                && backend.installed.values.allSatisfy {
                    $0.planningWidth == Self.largerScreen.width
                }
        }
        #expect(
            controller.layoutTable.values.allSatisfy {
                $0.placements.allSatisfy { $0.planningWidth == Self.largerScreen.width }
            }
        )
        #expect(backend.installedEventIDs == expectedIDs(at: 30, in: controller))
        expectVisibility(in: controller, backend, at: 30)
    }

    /// 窗口换到 backing scale 与尺寸都不同的屏幕：新表落地之前，在屏的弹幕一条不移除，就绪一条就原位换一条
    /// 新 scale 纹理，看得见的集合不变；新表落地的同一次调用里在屏的全部换到新车道（还没换纹理的按新尺寸
    /// 拉伸）；纹理排空之后全部是新 scale 的纹理。
    @Test
    func backingScaleChangeSwapsTexturesInPlaceThenMovesToTheNewLayout() async {
        let owner = UUID()
        let window = Size(width: 800, height: 360)
        let (controller, backend) = await laidOutController(at: 30, surfaceOwner: owner)
        let before = backend.installed
        let visibleBefore = visibleEventIDs(on: backend, at: 30, viewport: controller.viewport)
        let removed = backend.removedHistory.count
        backend.delaysPreparation = true

        resize(controller, owner: owner, window: window, screen: Self.largerScreen, backingScale: 3)
        #expect(backend.installed == before)
        #expect(backend.pendingEventIDs == Set(before.keys))
        backend.completePreparations(backend.pendingPreparationCount / 2)
        #expect(backend.installed == before)
        #expect(backend.removedHistory.count == removed)
        #expect(
            visibleEventIDs(on: backend, at: 30, viewport: controller.viewport) == visibleBefore
        )
        #expect(Set(backend.textureScales.values) == [2, 3])

        await waitForLayout(of: controller, backend, onScreenWidth: Self.largerScreen.width)
        let current = placementsByEventID(controller.layoutTable)
        #expect(backend.installed.allSatisfy { current[$0.key] == $0.value })
        expectNothingWithheld(in: controller, backend, at: 30)
        while backend.pendingPreparationCount > 0 {
            backend.completePreparations()
        }
        #expect(!backend.installed.isEmpty)
        #expect(backend.installed.allSatisfy { current[$0.key] == $0.value })
        #expect(backend.textureScales.values.allSatisfy { $0 == 3 })
        expectVisibility(in: controller, backend, at: 30)
    }

    /// 换 scale 与换屏同时发生，某条弹幕的新纹理被纹理字节上限拒绝：它仍换到新表的车道上，只是继续用旧
    /// scale 的纹理，不停在旧表的车道上与新表的邻居重叠。
    @Test
    func rejectedNewTextureStillMovesToTheNewLanes() async throws {
        let owner = UUID()
        let window = Size(width: 800, height: 360)
        let (controller, backend) = await laidOutController(at: 30, surfaceOwner: owner)
        let before = backend.installed
        backend.delaysPreparation = true

        resize(controller, owner: owner, window: window, screen: Self.largerScreen, backingScale: 3)
        await waitForLayout(of: controller, backend, onScreenWidth: Self.largerScreen.width)
        let desired = DanmakuMaterializer.desiredPlacements(
            in: controller.layoutTable,
            at: 30,
            viewport: controller.viewport
        )
        let moved = try #require(
            desired.first { placement in
                before[placement.request.event.id].map { $0 != placement } ?? false
            }
        )
        let eventID = moved.request.event.id
        backend.rejectedEventIDs = [eventID]
        while backend.pendingPreparationCount > 0 {
            backend.completePreparations()
        }

        #expect(backend.installed[eventID] == moved)
        #expect(backend.textureScales[eventID] == 2)
    }

    /// 窗口从 1x 屏挪到 2x 屏再挪回：新表落地之前旧表按 2x 对齐，在 2x 下纹理超限的长弹幕被拒、同一 scale
    /// 下不再请求，2x 的新表不含它；挪回 1x、新表落地后它重新出现。
    @Test
    func longDanmakuOversizedOnRetinaReappearsBackOnAStandardDisplay() async throws {
        let owner = UUID()
        let window = Size(width: 800, height: 360)
        let long = longTextEvent(id: "long", time: 29.5)
        try #require(fitsTexture(long, backingScale: 1))
        try #require(!fitsTexture(long, backingScale: 2))
        let (controller, backend) = makeController(owner: owner)
        resize(controller, owner: owner, window: window, screen: window, backingScale: 1)
        move(controller, to: 30, generation: 1, state: .paused)
        controller.setSegments([1: [long]], for: identity)
        await backend.waitUntil { backend.textureScales[long.id] == 1 }

        // 布局任务要回主线程才能交回新表，所以这两次对齐都用旧表。
        let requestsBefore = backend.preparationHistory.count
        resize(controller, owner: owner, window: window, screen: window, backingScale: 2)
        move(controller, to: 30 + Self.dragStep, generation: 1, state: .paused)
        #expect(backend.preparationHistory.dropFirst(requestsBefore) == [long.id])
        await backend.waitUntil { backend.installed.isEmpty }

        resize(controller, owner: owner, window: window, screen: window, backingScale: 1)
        while placementsByEventID(controller.layoutTable)[long.id] == nil {
            await Task.yield()
        }
        #expect(backend.textureScales[long.id] == 1)
    }

    /// 换屏重排用的更大屏幕。
    private static let largerScreen = Size(width: 1_600, height: 900)

    /// 原生拖动一步跨过的媒体时长：越过一个步长，所以每一步都要对齐。
    private static let dragStep = DanmakuPresentationController.reconcileStride * 1.6

    /// 等到按 `screenWidth` 规划的新布局表落地。
    ///
    /// 新表落地的同一次调用里在屏的弹幕原位换车道，backend 随之检查等待条件。
    private func waitForLayout(
        of controller: DanmakuPresentationController,
        _ backend: RecordingRenderingBackend,
        onScreenWidth screenWidth: Double
    ) async {
        await backend.waitUntil {
            !controller.layoutTable.isEmpty
                && controller.layoutTable.values.allSatisfy {
                    $0.placements.allSatisfy { $0.planningWidth == screenWidth }
                }
        }
    }

    /// 暂停在 `position` 的当前 identity 快照。
    private func pausedSnapshot(at position: Double) -> PlaybackTimelineSnapshot {
        snapshot(identity: identity, position: position, generation: 1, state: .paused)
    }

    /// 时钟层与快照一起到达 `position`：D 先变，快照随后作为检查节拍送达。
    private func move(
        _ controller: DanmakuPresentationController,
        to position: Double,
        generation: UInt64,
        state: PlaybackTimelineState = .playing
    ) {
        clock.time = position
        controller.apply(
            snapshot(identity: identity, position: position, generation: generation, state: state)
        )
    }

    private struct Size {
        let width: Double
        let height: Double
    }

    private func resize(
        _ controller: DanmakuPresentationController,
        owner: UUID,
        window: Size,
        screen: Size,
        backingScale: Double = 2
    ) {
        controller.updateSurface(
            width: window.width,
            height: window.height,
            screenWidth: screen.width,
            screenHeight: screen.height,
            backingScale: backingScale,
            ownerID: owner
        )
    }

    /// 由一个宿主接管的控制器；默认窗口与屏幕都是 800 × 360pt，取景框就是整张规划画布。
    private func makeController(
        owner: UUID = UUID(),
        window: Size = Size(width: 800, height: 360),
        screen: Size = Size(width: 800, height: 360)
    ) -> (DanmakuPresentationController, RecordingRenderingBackend) {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(backend: backend)
        controller.attachSurface(ownerID: owner, clock: clock)
        resize(controller, owner: owner, window: window, screen: screen)
        return (controller, backend)
    }

    /// D 与快照都停在 `position`、第一段已布局并挂上的控制器。
    private func laidOutController(
        at position: Double,
        surfaceOwner: UUID? = nil,
        window: Size = Size(width: 800, height: 360),
        screen: Size = Size(width: 800, height: 360)
    ) async -> (DanmakuPresentationController, RecordingRenderingBackend) {
        let (controller, backend) = makeController(
            owner: surfaceOwner ?? UUID(),
            window: window,
            screen: screen
        )
        move(controller, to: position, generation: 1, state: .paused)
        controller.setSegments([1: events()], for: identity)
        await backend.waitUntil { !backend.installed.isEmpty }
        return (controller, backend)
    }

    private func events() -> [DanmakuEvent] {
        (0..<600).map { offset in
            danmakuEvent(
                id: "event-\(offset)",
                time: Double(offset) * 0.6,
                mode: offset % 4 == 0 ? .top : .scrolling
            )
        }
    }

    private func expectedIDs(
        at position: Double,
        in controller: DanmakuPresentationController
    ) -> Set<String> {
        Set(
            DanmakuMaterializer.desiredPlacements(
                in: controller.layoutTable,
                at: position,
                viewport: controller.viewport
            )
            .map(\.request.event.id)
        )
    }

    private func expectNothingWithheld(
        in controller: DanmakuPresentationController,
        _ backend: RecordingRenderingBackend,
        at displayTime: Double,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        BiliDanmakuTests.expectNothingWithheld(
            on: backend,
            table: controller.layoutTable,
            viewport: controller.viewport,
            at: displayTime,
            sourceLocation: sourceLocation
        )
    }

    private func expectVisibility(
        in controller: DanmakuPresentationController,
        _ backend: RecordingRenderingBackend,
        at displayTime: Double,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        expectVisibilityMatchesTheTable(
            on: backend,
            table: controller.layoutTable,
            viewport: controller.viewport,
            at: displayTime,
            sourceLocation: sourceLocation
        )
    }
}
