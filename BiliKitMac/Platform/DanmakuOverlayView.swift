import AVFoundation
import AppKit
import BiliDanmaku
import BiliModels
import os

/// 将 renderer 的 layer 挂到弹幕时钟层下，放进当前 `AVPlayerView` 的 content overlay，并独占其尺寸更新权。
///
/// `ownerID` 防止已拆除 host 的迟到 layout/detach 清空新 host；零尺寸只表示 surface 尚未完成布局，
/// 不会扩大为另一个渲染会话。用 AppKit：弹幕由 Core Animation layer 树渲染，要作为 layer-backed
/// `NSView` 放进 `AVPlayerView` 的 content overlay，才能随 detached 全屏一起移动，见
/// docs/ARCHITECTURE.md「播放页布局」。鼠标事件只在正在显示的关联视频卡片上接收：点击经 `openLinkedVideo`
/// 在应用内打开该视频，悬停时换手形光标；其余位置 `hitTest` 返回 nil，点击与悬停照常落到下方的 AVKit 视图。
/// 卡片是否在显示按本视图时钟的 D 与卡片的时间区间判断（见 `CoreAnimationDanmakuRenderer.visibleLinkCards`），
/// 与画面上卡片的显隐同一个时间；光标只在鼠标移动时更新，卡片在静止的指针下出现或消失不换光标。
/// 不为卡片提供辅助功能元素：实测 AVKit 不把 content overlay 里的子元素交给辅助功能客户端，挂了也读不到。
///
/// 弹幕的时间来自 `clock`（`DanmakuTimebaseClock`）：时钟层的本地时间跟随绑定 item 的 timebase 时间，
/// 由 timebase 通知在后台队列上驱动，暂停、倍速、seek、缓冲停顿与播放结束都由它跟随，renderer 的
/// `rootLayer` 挂在它下面。它不会跟随 `replaceCurrentItem` 自动换绑：播放器宿主在 `currentItem` 变化时
/// 调用 `bind(to:)`，先让呈现控制器清屏，再换绑到新 item 的 timebase，否则旧弹幕会在新 item 的时间线上
/// 错位。本视图拥有时钟（释放时随之注销观察），并在主线程负责时钟层的 frame；时钟层的时间属性只由时钟
/// 自己的队列写。接管 surface 时把时钟交给呈现控制器作为显示时间 D(now) 的唯一来源，时钟每次写入后经
/// `displayClockDidChange(ownerID:)` 提醒控制器按新的 D 检查一次。
///
/// 这是 layer-backed 视图加自定义 layer（先 `wantsLayer` 再设 `layer`），不是 layer-hosting；视图本身
/// 从不绘制。暂停时增删弹幕 layer 由系统照常合成，不需要主动请求重新合成。
///
/// 弹幕按承载窗口的屏幕尺寸规划（取景框模型，见 docs/ARCHITECTURE.md「弹幕」），所以除了自身尺寸与
/// backing scale，还要在窗口换屏、屏幕分辨率变化时重新发布屏幕尺寸。这两个通知的观察在进入窗口时
/// 登记、离开窗口时注销，由本视图持有；回调都在主线程。
@MainActor
final class DanmakuOverlayView: NSView {
    private let renderer: CoreAnimationDanmakuRenderer
    private let controller: DanmakuPresentationController
    /// 按绑定 item 的 timebase 运行的时钟；renderer 的 `rootLayer` 在 surface 接管期间挂在它的时钟层下。
    private let clock = DanmakuTimebaseClock()
    /// 当前绑定的 timebase，只用来让同一 timebase 的重复绑定成为空操作。
    private var boundTimebase: CMTimebase?
    private let ownerID = UUID()
    private var previousSize: CGSize?
    private var previousScreenSize: CGSize?
    private var previousBackingScale: CGFloat?
    private var isSurfaceAttached = false
    /// 是否已登记换屏与屏幕参数通知；进入窗口时登记一次，离开窗口时按名字整体注销，不依赖窗口引用。
    private var isObservingScreenChanges = false
    /// 进入窗口后还没检查过时钟层的祖先；检查时 layer 链能走到窗口的根 layer 才判定并清掉。
    ///
    /// 进入窗口与第一次布局时 AppKit 往往还没把本视图的 layer 接进窗口的 layer 树，那时链上只有本视图自己，
    /// 查了等于没查；之后的布局与时钟写入回调（都在主线程）再查。
    private var needsAncestorCheck = false
    /// 点击关联视频卡片时打开该视频（参数是 BV 号）；由播放器宿主设置，为 nil 时卡片不接点击。
    var openLinkedVideo: ((String) -> Void)?
    /// 是否由本视图换上了手形光标；移出卡片或离开本视图时换回箭头，只还原自己换上的光标。
    private var showsLinkCursor = false

    init(
        renderer: CoreAnimationDanmakuRenderer,
        controller: DanmakuPresentationController
    ) {
        self.renderer = renderer
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        // 尺寸随视图变化时不带隐式过渡。
        clock.layer.actions = ["bounds": NSNull(), "position": NSNull()]
        clock.layer.anchorPoint = .zero
        layer?.addSublayer(clock.layer)
        // 只弱引用本视图、经它取控制器：控制器接管 surface 后持有时钟，回调若捕获控制器（包括 init 的同名
        // 参数）就成环，overlay 释放后控制器与时钟都留着。
        clock.setWriteHandler { [weak self] in
            guard let self else { return }
            self.controller.displayClockDidChange(ownerID: self.ownerID)
            self.checkClockAncestorsIfNeeded()
        }
        addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(linkCardClicked))
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        stopObservingScreenChanges()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            startObservingScreenChanges(of: window)
            attachSurfaceIfNeeded()
            needsAncestorCheck = true
            checkClockAncestorsIfNeeded()
        }
    }

    override func layout() {
        super.layout()
        clock.layer.frame = bounds
        updateSurfaceIfNeeded()
        checkClockAncestorsIfNeeded()
    }

    /// 时钟换绑到 `item` 的 timebase（nil 表示没有 item）；持有 surface 时先让呈现控制器清屏。
    ///
    /// 由播放器宿主在 `currentItem` 变化、开始观察 player 与拆除时调用；同一 timebase 重复调用是空操作。
    /// `AVPlayerItem` 创建后 `timebase` 就不是 nil，换 item 之后是另一个对象，所以按 timebase 判断换绑。
    func bind(to item: AVPlayerItem?) {
        let timebase = item?.timebase
        if item != nil, timebase == nil {
            DanmakuClockPrecondition.missingTimebase.report()
        }
        guard boundTimebase !== timebase else { return }
        if isSurfaceAttached {
            controller.playerItemWillChange(ownerID: ownerID)
        }
        boundTimebase = timebase
        clock.bind(timebase)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSurfaceIfNeeded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        visibleLinkCard(at: convert(point, from: superview)) == nil ? nil : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard trackingAreas.isEmpty else { return }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
        )
    }

    // 只由跟踪区直接投递，不调用 super：默认实现沿响应链转发，AVKit 自己的跟踪区已经收到同一次移动。
    override func mouseMoved(with event: NSEvent) {
        updateLinkCursor(isOverCard: visibleLinkCard(at: location(of: event)) != nil)
    }

    override func mouseExited(with event: NSEvent) {
        updateLinkCursor(isOverCard: false)
    }

    /// 卡片点击由手势识别器识别，不重写 `mouseDown`／`mouseUp`。
    ///
    /// AVKit 在播放器内容视图（本视图的祖先）上挂了延迟主键事件的点击识别器，按下与抬起要等它判定失败后才补发给
    /// 本视图，补发时已对不上卡片，点击就丢了。识别器直接收到原始事件，在抬起时识别。
    @objc private func linkCardClicked(_ recognizer: NSClickGestureRecognizer) {
        let point = recognizer.location(in: self)
        guard recognizer.state == .ended, let bvid = visibleLinkCard(at: point)?.card.bvid else {
            return
        }
        openLinkedVideo?(bvid)
    }

    /// 此刻正在显示的关联视频卡片，位置在本视图坐标（本视图的 layer 与视图同一坐标）。
    private func visibleLinkCards() -> [DanmakuVisibleLinkCard] {
        guard openLinkedVideo != nil, let layer, let displayTime = clock.displayTime() else {
            return []
        }
        return renderer.visibleLinkCards(displayTime: displayTime, in: layer)
    }

    /// `point`（本视图坐标）下最上面的一张关联视频卡片；后挂的卡片在上面。
    private func visibleLinkCard(at point: NSPoint) -> DanmakuVisibleLinkCard? {
        visibleLinkCards().last { $0.frame.contains(point) }
    }

    private func location(of event: NSEvent) -> NSPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func updateLinkCursor(isOverCard: Bool) {
        if isOverCard {
            NSCursor.pointingHand.set()
            showsLinkCursor = true
        } else if showsLinkCursor {
            NSCursor.arrow.set()
            showsLinkCursor = false
        }
    }

    /// 仅由当前 surface owner 发布窗口尺寸、屏幕尺寸与 backing scale。
    ///
    /// 窗口尺寸变化只移动取景框；屏幕尺寸或 scale 变化时呈现控制器整张重排，新表到来时在屏的弹幕原位换车道。
    /// 屏幕取 `frame` 而不是 `visibleFrame`：全屏时画面覆盖整块屏幕，菜单栏与 Dock 不占位。不在窗口里时
    /// 不发布（拿不到承载它的屏幕，用别的屏幕会按错误的规划尺寸重排）；窗口完全在屏幕外时屏幕尺寸按 0
    /// 发布，规划尺寸退回窗口尺寸。
    func updateSurfaceIfNeeded() {
        guard let window, bounds.width > 0, bounds.height > 0 else { return }
        let backingScale = window.backingScaleFactor
        let screenSize = window.screen?.frame.size ?? .zero
        guard
            bounds.size != previousSize
                || screenSize != previousScreenSize
                || backingScale != previousBackingScale
        else {
            return
        }
        previousSize = bounds.size
        previousScreenSize = screenSize
        previousBackingScale = backingScale
        controller.updateSurface(
            width: max(Double(bounds.width), 0),
            height: max(Double(bounds.height), 0),
            screenWidth: Double(screenSize.width),
            screenHeight: Double(screenSize.height),
            backingScale: Double(backingScale),
            ownerID: ownerID
        )
    }

    /// 撤销当前 host 的 ownership；不是 owner 时不会触碰后来接管的 surface。
    func detachSurface() {
        guard isSurfaceAttached else { return }
        isSurfaceAttached = false
        if controller.detachSurface(ownerID: ownerID),
            renderer.rootLayer.superlayer === clock.layer
        {
            renderer.rootLayer.removeFromSuperlayer()
        }
    }

    /// 窗口换到另一块屏幕、或屏幕分辨率与排列变化时重新发布尺寸；backing scale 的变化另由
    /// `viewDidChangeBackingProperties` 覆盖，但同 scale 不同尺寸的屏幕只有这两个通知。
    private func startObservingScreenChanges(of window: NSWindow) {
        guard !isObservingScreenChanges else { return }
        isObservingScreenChanges = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidChange),
            name: NSWindow.didChangeScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// `object` 传 nil：注销本视图在这个名字下的全部登记，与当时登记的是哪个窗口无关。
    private func stopObservingScreenChanges() {
        guard isObservingScreenChanges else { return }
        isObservingScreenChanges = false
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// 检查时钟层的祖先都没有改时间属性。
    ///
    /// 时钟按 `CACurrentMediaTime()` 写时钟层的 `beginTime`，祖先的时间属性恒等时父层的本地时间才等于宿主
    /// 时间；普通窗口、原生全屏、detached 全屏与画中画下都成立。每次进入窗口（含 AVKit 把画面移到别的窗口）
    /// 之后检查一次：layer 链还没接到窗口的根 layer 时不判定，留到下一次布局或时钟写入；判定后不成立时只
    /// 报告，不尝试换算。
    private func checkClockAncestorsIfNeeded() {
        guard needsAncestorCheck, let window else { return }
        let contentView = window.contentView
        let roots = [contentView?.superview?.layer, contentView?.layer].compactMap { $0 }
        var chain: [CALayer] = []
        var ancestor = clock.layer.superlayer
        while let layer = ancestor {
            chain.append(layer)
            ancestor = layer.superlayer
        }
        guard chain.contains(where: { layer in roots.contains { $0 === layer } }) else { return }
        needsAncestorCheck = false
        if !chain.allSatisfy({ $0.speed == 1 && $0.timeOffset == 0 && $0.beginTime == 0 }) {
            DanmakuClockPrecondition.ancestorTiming.report()
        }
    }

    @objc private func screenDidChange(_ notification: Notification) {
        updateSurfaceIfNeeded()
    }

    private func attachSurfaceIfNeeded() {
        guard !isSurfaceAttached else { return }
        isSurfaceAttached = true
        controller.attachSurface(ownerID: ownerID, clock: clock)
        clock.layer.addSublayer(renderer.rootLayer)
        previousSize = nil
        previousScreenSize = nil
        previousBackingScale = nil
        updateSurfaceIfNeeded()
    }
}

/// 弹幕时钟依赖、但不能自己保证的平台前提；不成立时显示时间与画面错开。
///
/// DEBUG 下断言失败；Release 下只记一条固定分类的日志，不含时间、位置或内容身份（docs/SECURITY-MODEL.md §8）。
private enum DanmakuClockPrecondition: String {
    case ancestorTiming = "danmaku clock ancestor layer has non-identity timing"
    case missingTimebase = "player item has no timebase for the danmaku clock"

    // subsystem 跟随渠道 Bundle ID，Console 里开发版与安装版的日志可以分开筛选。
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BiliKit",
        category: "DanmakuClock"
    )

    func report() {
        assertionFailure(rawValue)
        Self.log.error("\(rawValue, privacy: .public)")
    }
}

/// 时钟层发布的就是 `BiliDanmaku` 的显示时间 D；`displayTime()` 的实现与线程规则见 `DanmakuTimebaseClock`。
extension DanmakuTimebaseClock: DanmakuDisplayClock {}
