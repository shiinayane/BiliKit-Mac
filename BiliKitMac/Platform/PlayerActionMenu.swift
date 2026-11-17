import AppKit
import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import BiliVideoDetailFeature
import SwiftUI

/// 播放器动作菜单的意图：加入稍后再看、能否发送弹幕、取当前视频的网页地址与 BV 号、暂停播放、跳到某一章，读写「播放结束后」
/// 偏好。
///
/// 由 `WindowAdapters` 的播放器内容用视频模型、章节模型、播放引擎的时间线、跳转与暂停、窗口的写入入口构造（`make`），交给
/// `PlayerActionMenuController`。门槛与写入在窗口的写入协调者里，这里只决定当下能不能做、给什么提示；协调者没有发出
/// 写入时不给提示，免得说出没有发生的事。不持有状态。
struct PlayerActionMenuActions {
    /// 刷新可用状态时据此决定「添加到稍后再看」是否可用。
    let canAddToWatchLater: @MainActor () -> Bool
    let addToWatchLater: @MainActor () -> PlayerActionFeedback?
    /// 刷新可用状态时据此决定「发送弹幕…」是否可用（`DanmakuComposerModel.canPresent`）；执行时由输入胶囊再核对一次。
    let canPostDanmaku: @MainActor () -> Bool
    /// 当前视频带分 P 与时间的网页地址；没有可操作的视频时为 nil（见 `VideoViewModel.shareURL`）。
    let shareURL: @MainActor () -> URL?
    /// 当前可操作视频的 BV 号（`VideoViewModel.operableBVID`）。
    let bvid: @MainActor () -> String?
    let pausePlayback: @MainActor () -> Void
    let endBehavior: @MainActor () -> PlaybackEndBehavior
    let setEndBehavior: @MainActor (PlaybackEndBehavior) -> Void
    /// 播放器里正在播放的分 P 的分段章节与当前章节下标（`VideoChapterModel`）；章节不属于正在播放的 item 时为空。
    let chapters: @MainActor () -> (chapters: [VideoChapter], current: Int?)
    /// 跳到当前 item 的某一秒并继续播放；跳不了（还没有可跳的画面）时返回 false。
    ///
    /// 跳过去后的章节提示由章节模型发出，菜单不另外提示。
    let seek: @MainActor (Int) -> Bool

    @MainActor
    static func make(
        videoModel: VideoViewModel,
        chapterModel: VideoChapterModel,
        timeline: @escaping @MainActor () -> PlaybackTimelineSnapshot,
        seek: @escaping @MainActor (Int) -> Bool,
        pausePlayback: @escaping @MainActor () -> Void,
        endBehavior: PlaybackEndBehaviorStore,
        window: PlayerWindowContext
    ) -> Self {
        Self(
            canAddToWatchLater: { window.canWriteAccount() && videoModel.operableBVID != nil },
            addToWatchLater: {
                guard window.canWriteAccount() else { return .signInRequired }
                guard let bvid = videoModel.operableBVID else { return .unavailable }
                return window.addToWatchLater(bvid) ? .watchLaterRequested : nil
            },
            canPostDanmaku: { window.danmakuComposer.canPresent },
            shareURL: { videoModel.shareURL(timeline: timeline()) },
            bvid: { videoModel.operableBVID },
            pausePlayback: pausePlayback,
            endBehavior: { endBehavior.behavior },
            setEndBehavior: { endBehavior.behavior = $0 },
            chapters: {
                let chapters = chapterModel.chapters(playing: timeline().identity)
                return (chapters, chapters.isEmpty ? nil : chapterModel.currentIndex)
            },
            seek: seek
        )
    }
}

/// 动作菜单操作与「播放结束后」生效时在播放器顶部的提示。
///
/// 加入稍后再看是一次写入（`isWriteRequest`），结果只由写入结果的一处说明，与点赞快捷键相同：全屏时在结果的位置先显示
/// 「正在添加到稍后再看」。`unavailable` 是执行时发现已没有可操作的视频（全屏下菜单的可用状态可能是旧的）。
enum PlayerActionFeedback: Equatable {
    case watchLaterRequested
    case signInRequired
    /// 未登录时呼出弹幕输入胶囊。
    case danmakuSignInRequired
    case unavailable
    case linkCopied
    case bvidCopied
    /// 选了「播放结束后」的一项，或播完时按它动作了（例如单集循环从头再播）。
    case endBehavior(PlaybackEndBehavior)
    /// 单集循环要从头再播，但播放器没能回到开头、仍停在结尾。
    case replayFailed
    /// 自动连播或列表循环正在换到下一个分 P 或下一集；`title` 是它的标题。
    case advancing(title: String)
    /// 下一集缺少能播放它的身份，或它的分 P 解析失败，停下。
    case nextUnavailable

    var tier: PlayerShortcutFeedback.Tier {
        switch self {
        case .linkCopied, .bvidCopied, .endBehavior: .echo
        case .watchLaterRequested, .signInRequired, .danmakuSignInRequired, .unavailable,
            .replayFailed, .advancing, .nextUnavailable:
            .message
        }
    }

    var isWriteRequest: Bool { self == .watchLaterRequested }

    var label: String {
        switch self {
        case .watchLaterRequested: AppStrings.localized("正在添加到稍后再看")
        case .signInRequired: AppStrings.localized("登录后可添加到稍后再看")
        case .danmakuSignInRequired: AppStrings.localized("登录后可发送弹幕")
        case .unavailable: AppStrings.localized("暂时无法操作当前视频")
        case .linkCopied: AppStrings.localized("已拷贝链接")
        case .bvidCopied: AppStrings.localized("已拷贝 BV 号")
        case .endBehavior(let behavior): behavior.title
        case .replayFailed: AppStrings.localized("无法从头重播")
        case .advancing(let title): AppStrings.localized("接着播放：\(title)")
        case .nextUnavailable: AppStrings.localized("下一集无法播放")
        }
    }

    var symbolName: String {
        switch self {
        case .watchLaterRequested: "clock"
        case .signInRequired, .danmakuSignInRequired: "person.crop.circle"
        case .unavailable: "exclamationmark.circle"
        case .linkCopied: "link"
        case .bvidCopied: "doc.on.doc"
        case .endBehavior(let behavior): behavior.symbolName
        case .replayFailed, .nextUnavailable: "exclamationmark.circle"
        case .advancing: "forward.end"
        }
    }
}

extension PlaybackEndBehavior {
    /// 菜单项与提示共用的名字。
    var title: String {
        switch self {
        case .stop: AppStrings.localized("不循环")
        case .repeatOne: AppStrings.localized("单集循环")
        case .autoAdvance: AppStrings.localized("自动连播")
        case .repeatList: AppStrings.localized("列表循环")
        }
    }

    var symbolName: String {
        switch self {
        case .stop: "arrow.right.to.line"
        case .repeatOne: "repeat.1"
        case .autoAdvance: "forward.end"
        case .repeatList: "repeat"
        }
    }
}

/// AVKit 控制条动作菜单（`AVPlayerView.actionPopUpButtonMenu`）的内容与执行：稍后再看、发送弹幕、链接与 BV 号，以及
/// 「播放结束后」单选。
///
/// 用 AppKit：菜单由 AVKit 的原生控制条弹出，只接受 `NSMenu`。窗口下在控制条的动作菜单按钮里；全屏下 AVKit 把它收进
/// 浮动控制条的「»」→「其他」子菜单。由 `NativePlayerHostView` 持有；菜单项只在创建时建一次，之后只原地改可用状态与勾选，
/// 菜单打开期间宿主更新也不会删掉用户正指着的项；唯一的例外是「章节」子菜单，章节列表变了（换了分 P）才重建它的项。宿主在创建与每次更新时经 `update` 换上意图并刷新可用状态，窗口下菜单
/// 每次打开时（`menuNeedsUpdate`）再刷新一次；全屏时 AVKit 不保证调用它，可用状态可能停在上次刷新时，所以执行时再核对，
/// 已没有可操作的视频就提示，不对旧视频动作。「播放结束后」是设备级偏好：另一个窗口改了它，全屏中的这个菜单在下次刷新前
/// 可能还勾着旧值，播完时的处理总是读当下的值。打开网页只经 SwiftUI 的 `OpenURLAction`，地址只由合法 BVID 拼出，
/// 见 SECURITY-MODEL §4。不持有 Task。
@MainActor
final class PlayerActionMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    /// 宿主第一次 `update` 之前为 nil，各项禁用。
    private var actions: PlayerActionMenuActions?
    private var openURL: OpenURLAction?
    /// 操作后的播放器提示；宿主接到播放器浮层。
    var presentFeedback: (PlayerActionFeedback) -> Void = { _ in }
    /// 「发送弹幕…」；宿主接到播放器浮层的输入胶囊（`DanmakuComposerModel.present`）。
    var openDanmakuComposer: () -> Void = {}
    /// 「章节」子菜单：只在正在播放的分 P 有分段章节时出现（连同它下面的分隔线）。
    ///
    /// 章节变了才重建子菜单项，否则只改勾选，菜单打开期间的刷新不会删掉用户正指着的章节。
    private lazy var chaptersItem: NSMenuItem = {
        let item = item(AppStrings.localized("章节"), symbol: "list.bullet.rectangle", action: nil)
        item.submenu = NSMenu()
        return item
    }()
    private let chaptersSeparator = NSMenuItem.separator()
    /// 子菜单当前列出的章节，菜单项的 `representedObject` 是下标。
    private var listedChapters: [VideoChapter] = []

    private lazy var watchLaterItem = item(
        VideoCardMenuText.addToWatchLater,
        symbol: "clock",
        action: #selector(addToWatchLater)
    )
    private lazy var danmakuItem = item(
        AppStrings.localized("发送弹幕…"),
        symbol: "text.bubble",
        action: #selector(postDanmaku)
    )
    private lazy var videoItems = [
        item(VideoCardMenuText.copyLink, symbol: "link", action: #selector(copyLink)),
        item(AppStrings.localized("拷贝 BV 号"), symbol: "doc.on.doc", action: #selector(copyBVID)),
        item(VideoCardMenuText.openInBrowser, symbol: "globe", action: #selector(openInBrowser))
    ]
    /// 「播放结束后」的单选项，顺序与 `PlaybackEndBehavior.allCases` 一致；`representedObject` 是原始值。
    private lazy var endBehaviorItems = PlaybackEndBehavior.allCases.map { behavior in
        let item = item(
            behavior.title,
            symbol: behavior.symbolName,
            action: #selector(chooseEndBehavior)
        )
        item.representedObject = behavior.rawValue
        return item
    }

    override init() {
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(chaptersItem)
        menu.addItem(chaptersSeparator)
        menu.addItem(watchLaterItem)
        menu.addItem(danmakuItem)
        menu.addItem(.separator())
        videoItems.forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: AppStrings.localized("播放结束后")))
        endBehaviorItems.forEach(menu.addItem)
        refreshItemStates()
    }

    /// 换上新的意图与打开网页的入口，并刷新可用状态。
    func update(actions: PlayerActionMenuActions, openURL: OpenURLAction) {
        self.actions = actions
        self.openURL = openURL
        refreshItemStates()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshItemStates()
    }

    private func refreshItemStates() {
        watchLaterItem.isEnabled = actions?.canAddToWatchLater() == true
        danmakuItem.isEnabled = actions?.canPostDanmaku() == true
        let hasVideo = actions?.bvid() != nil
        for item in videoItems {
            item.isEnabled = hasVideo
        }
        refreshChapters()
        // 偏好与当前视频无关，没有视频时也可以改；宿主第一次 `update` 之前没有意图，禁用。
        let selected = actions?.endBehavior()
        for item in endBehaviorItems {
            item.isEnabled = actions != nil
            item.state = item.representedObject as? String == selected?.rawValue ? .on : .off
        }
    }

    private func refreshChapters() {
        let (chapters, current) = actions?.chapters() ?? ([], nil)
        chaptersItem.isHidden = chapters.isEmpty
        chaptersSeparator.isHidden = chapters.isEmpty
        guard let submenu = chaptersItem.submenu else { return }
        if chapters != listedChapters {
            listedChapters = chapters
            submenu.removeAllItems()
            for (index, chapter) in chapters.enumerated() {
                let item = NSMenuItem(
                    title: "\(index + 1). \(chapter.title)",
                    action: #selector(chooseChapter),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = index
                submenu.addItem(item)
            }
        }
        for item in submenu.items {
            item.state = item.representedObject as? Int == current ? .on : .off
        }
    }

    private func item(_ title: String, symbol: String, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    @objc private func addToWatchLater() {
        guard let feedback = actions?.addToWatchLater() else { return }
        presentFeedback(feedback)
    }

    @objc private func postDanmaku() {
        openDanmakuComposer()
    }

    @objc private func copyLink() {
        guard let url = actions?.shareURL() else { return presentFeedback(.unavailable) }
        VideoLinkPasteboard.copy(url)
        presentFeedback(.linkCopied)
    }

    @objc private func copyBVID() {
        guard let bvid = actions?.bvid() else { return presentFeedback(.unavailable) }
        VideoLinkPasteboard.copy(text: bvid)
        presentFeedback(.bvidCopied)
    }

    /// 执行时再核对一次，章节已经不是正在播放的这份就提示、不按旧的秒数跳。
    ///
    /// 全屏菜单可能停在上一个分 P 的章节上。跳过去后的章节提示由章节模型发出。
    @objc private func chooseChapter(_ sender: NSMenuItem) {
        guard let actions, let index = sender.representedObject as? Int,
            listedChapters.indices.contains(index),
            actions.chapters().chapters == listedChapters,
            actions.seek(listedChapters[index].startSeconds)
        else { return presentFeedback(.unavailable) }
    }

    @objc private func chooseEndBehavior(_ sender: NSMenuItem) {
        guard let actions,
            let behavior = (sender.representedObject as? String).flatMap(
                PlaybackEndBehavior.init(rawValue:)
            )
        else { return }
        actions.setEndBehavior(behavior)
        refreshItemStates()
        presentFeedback(.endBehavior(behavior))
    }

    /// 带当前时间打开网页，先暂停应用内播放：网页会自动播放，两边同时出声。
    @objc private func openInBrowser() {
        guard let actions, let openURL, let url = actions.shareURL() else {
            return presentFeedback(.unavailable)
        }
        actions.pausePlayback()
        openURL(url)
    }
}
