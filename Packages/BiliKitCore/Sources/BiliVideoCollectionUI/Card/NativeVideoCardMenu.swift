import AppKit
import BiliUI
import SwiftUI

/// 视频卡片的菜单描述：右键／Control-点按与读屏「显示菜单」弹出的 `NSMenu`、卡片的读屏自定义操作（VoiceOver「操作」
/// 转子）以及网格的 ⌘⌫ 都只由它生成，几处的项、顺序与标题因此一致。
///
/// 项按分组排列，组与组之间在菜单里画分隔线（写操作一组、链接一组）。菜单与读屏自定义操作只有两处差别：禁用的项在
/// 菜单里显示为灰色，读屏自定义操作没有“禁用”的表示，所以只列出可用的项（未登录或复核中时写操作项不进入转子）；子菜单
/// 在读屏操作里没有层级，展开为带父项名字的各项（`actionableItems`）。
///
/// 各来源的 Feature 按卡片构造（经 `NativeVideoGridView` 与竖向视频行列表的 `cardMenu` 注入），哪些项出现由来源决定；
/// 集合视图只在命中卡片时取用，取到 nil 就不弹菜单。描述是一次性的值：不持有卡片、集合视图或会话，每次弹出、读屏
/// 询问或执行时重新构造。动作在主线程同步调用，只转发意图：写操作的 Task 由 App 的写入协调者拥有。
@MainActor
package struct NativeVideoCardMenu {
    /// 菜单项的快捷键；只有作用于选中卡片、且在网格里有对应按键处理的才给出。
    package enum KeyEquivalent: Sendable, Equatable {
        /// ⌘⌫：网格选中卡片时由集合视图按同一份描述执行（`NativeVideoCollectionView.keyDown`）。
        case commandDelete
    }

    /// 一个菜单项：稳定标识、标题、SF Symbol 名、是否可用、快捷键与动作；有子项时只展开子菜单。
    package struct Item {
        /// 同一份描述里不重复的稳定标识（含子项）；读屏操作执行时按它在此刻的描述里找回这一项，不依赖本地化的标题。
        package let id: String
        package let title: String
        package let systemImage: String
        package let isEnabled: Bool
        package let keyEquivalent: KeyEquivalent?
        package let action: @MainActor () -> Void
        /// 子项；非空时这一项只展开子菜单，自身的 `action` 不执行。
        package let submenu: [Item]

        package init(
            id: String,
            title: String,
            systemImage: String,
            isEnabled: Bool = true,
            keyEquivalent: KeyEquivalent? = nil,
            action: @escaping @MainActor () -> Void
        ) {
            self.id = id
            self.title = title
            self.systemImage = systemImage
            self.isEnabled = isEnabled
            self.keyEquivalent = keyEquivalent
            self.action = action
            submenu = []
        }

        /// 只展开子菜单的一项；子项都不可用时它也不可用。
        package init(id: String, title: String, systemImage: String, submenu: [Item]) {
            self.id = id
            self.title = title
            self.systemImage = systemImage
            isEnabled = submenu.contains(where: \.isEnabled)
            keyEquivalent = nil
            action = {}
            self.submenu = submenu
        }
    }

    /// 非空的分组，按显示顺序。
    package let sections: [[Item]]

    /// 全部顶层项，按显示顺序。
    package var items: [Item] { sections.flatMap(\.self) }

    /// 可直接执行的项，按显示顺序：子菜单展开为各个子项，标题带上所属的父项（读屏操作没有层级，只看标题）。
    package var actionableItems: [Item] {
        items.flatMap { item in
            guard !item.submenu.isEmpty else { return [item] }
            return item.submenu.map { child in
                Item(
                    id: child.id,
                    title: VideoCardMenuText.submenuActionTitle(
                        parent: item.title,
                        child: child.title
                    ),
                    systemImage: child.systemImage,
                    isEnabled: child.isEnabled,
                    keyEquivalent: child.keyEquivalent,
                    action: child.action
                )
            }
        }
    }

    /// 空组被丢弃；没有任何项时构造失败：调用方据此不弹菜单，也不给读屏空的操作列表。
    package init?(sections: [[Item]]) {
        let sections = sections.filter { !$0.isEmpty }
        guard !sections.isEmpty else { return nil }
        self.sections = sections
    }

    /// 带 `keyEquivalent` 且可用的项；网格按快捷键执行时取它。
    package func enabledItem(for keyEquivalent: KeyEquivalent) -> Item? {
        actionableItems.first { $0.isEnabled && $0.keyEquivalent == keyEquivalent }
    }

    /// 按稳定标识找回此刻仍可用的项（含子项）；读屏操作执行前经这里核对。
    package func enabledItem(id: String) -> Item? {
        actionableItems.first { $0.id == id && $0.isEnabled }
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        // 关掉自动启用：否则 AppKit 看到 target 响应 action 就会把禁用的项重新启用。
        menu.autoenablesItems = false
        for (index, section) in sections.enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }
            for item in section {
                menu.addItem(Self.makeMenuItem(item))
            }
        }
        return menu
    }

    private static func makeMenuItem(_ item: Item) -> NSMenuItem {
        guard item.submenu.isEmpty else {
            let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            menuItem.image = NSImage(
                systemSymbolName: item.systemImage,
                accessibilityDescription: nil
            )
            menuItem.isEnabled = item.isEnabled
            let submenu = NSMenu(title: item.title)
            submenu.autoenablesItems = false
            for child in item.submenu {
                submenu.addItem(makeMenuItem(child))
            }
            menuItem.submenu = submenu
            return menuItem
        }
        let target = NativeVideoCardMenuActionTarget(action: item.action)
        let menuItem = NSMenuItem(
            title: item.title,
            action: #selector(NativeVideoCardMenuActionTarget.performAction(_:)),
            keyEquivalent: ""
        )
        menuItem.image = NSImage(systemSymbolName: item.systemImage, accessibilityDescription: nil)
        menuItem.isEnabled = item.isEnabled
        switch item.keyEquivalent {
        case .commandDelete:
            menuItem.keyEquivalent = "\u{8}"
            menuItem.keyEquivalentModifierMask = .command
        case nil:
            break
        }
        // `target` 是弱引用，由 `representedObject` 持有动作对象直到菜单项释放。
        menuItem.target = target
        menuItem.representedObject = target
        return menuItem
    }
}

extension NativeVideoCardMenu {
    /// 稍后再看写操作在这张卡片上的形态：其他来源给「添加到稍后再看」，稍后再看页给「从稍后再看移除」。
    package enum WatchLaterAction: Sendable {
        case add
        case remove
    }

    /// 各来源共用的卡片菜单：写操作一组（稍后再看、收藏到…、收藏夹页的从此收藏夹移除），链接一组（拷贝链接、在浏览器
    /// 中打开）。
    ///
    /// 菜单只看视频 ID 与能否进入播放，网格卡片与空间投稿行都按这两项调用。
    /// `webPageURL` 由 Feature 用 BiliModels 的 `BVID.webPageURL` 按卡片 ID 构造，为 nil 表示卡片 ID 不是合法 BVID：只可能有
    /// 「从此收藏夹移除」（收藏夹里没有 BVID 的失效视频）。链接项、「添加到稍后再看」与「收藏到…」只给可进入播放的卡片；
    /// 两种移除也给不可用卡片（失效的视频只能移除）。`removeFromFavoriteFolder` 只由收藏夹页给出（视频条目才有），
    /// 带 ⌘⌫；稍后再看页的移除占用 ⌘⌫，两者不会同时出现。`additionalWriteItems` 是来源自己的写操作项（首页推荐的
    /// 「不感兴趣」，来源按 `writing` 自行决定给不给），排在写操作一组末尾，卡片 ID 不是合法 BVID 时不出现。`writing` 为 nil（没有注入写入口）时没有写操作
    /// 项；有入口但此刻不满足门槛时写操作项显示为禁用。
    package static func video(
        videoID: String,
        isActivatable: Bool,
        webPageURL: URL?,
        openURL: OpenURLAction,
        writing: VideoCardAccountWriting?,
        watchLater: WatchLaterAction,
        removeFromFavoriteFolder: (@MainActor @Sendable () -> Void)? = nil,
        additionalWriteItems: [Item] = []
    ) -> NativeVideoCardMenu? {
        let folderRemoval = Item.favoriteFolderRemoval(removeFromFavoriteFolder, writing: writing)
        guard let webPageURL else {
            return NativeVideoCardMenu(sections: [folderRemoval])
        }
        return NativeVideoCardMenu(
            sections: [
                Item.watchLater(
                    watchLater,
                    videoID: videoID,
                    isActivatable: isActivatable,
                    writing: writing
                )
                    + Item.favorites(
                        videoID: videoID,
                        isActivatable: isActivatable,
                        writing: writing
                    )
                    + folderRemoval
                    + additionalWriteItems,
                Item.videoLinks(
                    isActivatable: isActivatable,
                    webPageURL: webPageURL,
                    openURL: openURL
                )
            ]
        )
    }
}

extension NativeVideoCardMenu.Item {
    /// 「拷贝链接」「在浏览器中打开」两项：只给可进入播放的卡片，否则为空。
    ///
    /// 拷贝经 `VideoLinkPasteboard`；打开只经系统的 `OpenURLAction`，不预取、不附加凭据，见 SECURITY-MODEL §4。
    static func videoLinks(
        isActivatable: Bool,
        webPageURL: URL,
        openURL: OpenURLAction
    ) -> [Self] {
        guard isActivatable else { return [] }
        return [
            Self(id: "copyLink", title: VideoCardMenuText.copyLink, systemImage: "link") {
                VideoLinkPasteboard.copy(webPageURL)
            },
            Self(
                id: "openInBrowser",
                title: VideoCardMenuText.openInBrowser,
                systemImage: "globe"
            ) {
                openURL(webPageURL)
            }
        ]
    }

    /// 稍后再看的写操作项；动作只把卡片 ID 交给写入口，门槛与请求由 App 的写入协调者在执行时重新核对。
    @MainActor
    static func watchLater(
        _ action: NativeVideoCardMenu.WatchLaterAction,
        videoID bvid: String,
        isActivatable: Bool,
        writing: VideoCardAccountWriting?
    ) -> [Self] {
        guard let writing else { return [] }
        switch action {
        case .add:
            guard isActivatable else { return [] }
            return [
                Self(
                    id: "addToWatchLater",
                    title: VideoCardMenuText.addToWatchLater,
                    systemImage: "text.badge.plus",
                    isEnabled: writing.isAvailable()
                ) { writing.addToWatchLater(bvid) }
            ]
        case .remove:
            return [
                Self(
                    id: "removeFromWatchLater",
                    title: VideoCardMenuText.removeFromWatchLater,
                    systemImage: "text.badge.minus",
                    isEnabled: writing.isAvailable(),
                    keyEquivalent: .commandDelete
                ) { writing.removeFromWatchLater(bvid) }
            ]
        }
    }
}

extension NativeVideoCardMenu.Item {
    /// 「收藏到…」：只给可进入播放的卡片；动作只打开面板，写入在面板确认时由写入协调者发出。
    @MainActor
    static func favorites(
        videoID bvid: String,
        isActivatable: Bool,
        writing: VideoCardAccountWriting?
    ) -> [Self] {
        guard let writing, isActivatable else { return [] }
        return [
            Self(
                id: "chooseFavoriteFolders",
                title: VideoCardMenuText.addToFavorites,
                systemImage: "star",
                isEnabled: writing.isAvailable()
            ) { writing.chooseFavoriteFolders(bvid) }
        ]
    }

    /// 「从此收藏夹移除」：收藏夹页按显示中的收藏夹与条目给出动作，没有给出（其他来源、不是视频条目）时为空。
    @MainActor
    static func favoriteFolderRemoval(
        _ action: (@MainActor @Sendable () -> Void)?,
        writing: VideoCardAccountWriting?
    ) -> [Self] {
        guard let writing, let action else { return [] }
        return [
            Self(
                id: "removeFromFavoriteFolder",
                title: VideoCardMenuText.removeFromFavoriteFolder,
                systemImage: "star.slash",
                isEnabled: writing.isAvailable(),
                keyEquivalent: .commandDelete,
                action: action
            )
        ]
    }
}

/// `NSMenuItem` 的 target-action 接收者：只持有一个菜单项的动作，随菜单项释放。
@MainActor
private final class NativeVideoCardMenuActionTarget: NSObject {
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func performAction(_ sender: Any?) {
        action()
    }
}

extension NativeVideoCardCollectionView {
    /// 卡片菜单的唯一取用处：右键、读屏自定义操作、读屏「显示菜单」与 ⌘⌫ 都经这里，只把卡片 ID 交给 `cardMenu`。
    func cardMenu(for item: any NativeVideoMenuTargetItem) -> NativeVideoCardMenu? {
        guard let id = item.representedVideoID else { return nil }
        return cardMenu?(id)
    }

    /// 读屏「显示菜单」：以卡片中心的右键事件走右键同一条路径（`rightMouseDown` → `menu(for:)` → `willOpenMenu`／
    /// `didCloseMenu`），菜单、弹出位置与上下文描边都与右键一致。
    ///
    /// 推到下一轮 runloop 再弹：菜单的跟踪循环会一直阻塞到菜单关闭，在辅助功能请求里同步弹出会让读屏等到超时。
    /// 届时卡片可能已被复用给其他视频，所以按发起时的 ID 重新核对。
    func presentCardMenu(for item: any NativeVideoMenuTargetItem) -> Bool {
        guard let id = item.representedVideoID, cardMenu(for: item) != nil else { return false }
        DispatchQueue.main.async { [weak self, weak item] in
            guard
                let self,
                let item,
                item.representedVideoID == id,
                let window = self.window,
                let event = NSEvent.mouseEvent(
                    with: .rightMouseDown,
                    location: item.view.convert(
                        NSPoint(x: item.view.bounds.midX, y: item.view.bounds.midY),
                        to: nil
                    ),
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            else { return }
            self.rightMouseDown(with: event)
        }
        return true
    }

    /// 卡片的读屏自定义操作：查询时只列出可用项，执行时按查询时的卡片 ID 重新取一次菜单、按项的稳定标识找到仍可用的项
    /// 再执行。
    ///
    /// 读屏可能缓存操作列表，卡片在此期间会被复用给别的视频、账户门槛也可能变化；按 ID 与当下的描述核对，避免对另一个
    /// 视频或在不满足门槛时执行写操作（与 `presentCardMenu` 同一做法）。
    func accessibilityCustomActions(
        for item: any NativeVideoMenuTargetItem
    ) -> [NSAccessibilityCustomAction]? {
        guard let id = item.representedVideoID, let menu = cardMenu(for: item) else { return nil }
        let actions = menu.actionableItems.filter(\.isEnabled).map { menuItem in
            let itemID = menuItem.id
            return NSAccessibilityCustomAction(name: menuItem.title) { [weak self, weak item] in
                // 读屏在主线程执行自定义操作。
                MainActor.assumeIsolated {
                    guard
                        let self,
                        let item,
                        item.representedVideoID == id,
                        let current = self.cardMenu(for: item)?.enabledItem(id: itemID)
                    else { return false }
                    current.action()
                    return true
                }
            }
        }
        return actions.isEmpty ? nil : actions
    }
}

extension NativeVideoMenuTargetItem {
    /// 集合项的读屏入口（视频卡片、空间投稿行）取操作与弹出菜单都转给所在的集合视图；不在集合视图里时没有菜单。
    package var accessibilityCardActions: [NSAccessibilityCustomAction]? {
        (collectionView as? NativeVideoCardCollectionView)?.accessibilityCustomActions(for: self)
    }

    package func presentCardMenu() -> Bool {
        (collectionView as? NativeVideoCardCollectionView)?.presentCardMenu(for: self) ?? false
    }
}
