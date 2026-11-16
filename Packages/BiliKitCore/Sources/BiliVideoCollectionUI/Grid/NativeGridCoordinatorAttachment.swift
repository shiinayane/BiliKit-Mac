import AppKit

/// 网格 Coordinator 的挂载与拆除：首次建滚动视图、保活时摘下与挂回、不可逆的 `reset()`；顺序要求见
/// `NativeGridView.Coordinator`。
extension NativeGridView.Coordinator {
    /// 首次建好滚动视图；保活的网格再次出现时原样返回，按新视口重排与恢复留给下一轮。
    ///
    /// 只由 `makeNSView` 调用，每次返回的滚动视图同一时刻只能挂在一处（保活容器保证同一 Coordinator 不会同时
    /// 给两个实例）；挂回后由随之而来的 `update` 交回当前内容与回调。
    func attachScrollView() -> NSScrollView {
        guard hasMadeScrollView else { return makeScrollView() }
        isDetached = false
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isDetached else { return }
            self.resizeDocument()
            self.restorePendingOffsetIfPossible()
            self.viewportDidChange()
        }
        return scrollView
    }

    /// 保活的网格被摘下（只由 `dismantleNSView` 调用）：先同步最后的滚动位置，再停用卡片动作，直到挂回后的
    /// `update` 交回。
    ///
    /// 不移除观察、不清内容与锚点。离开窗口时自动 contentInsets 会变、bounds 可能被夹取，摘下期间的滚动不记录、
    /// 不判断翻页，否则会把过渡偏移写回 binding、把尾标记成已触发而丢掉那次翻页。滚动位置与回顶确认的回调照旧
    /// 指向窗口状态：它们比网格活得久，离开期间落地的回顶仍要确认。卡片正显示的图在离开窗口之前
    /// （`onWillLeaveWindow`）就已收走。
    func detach() {
        guard !isReset, !isDetached else { return }
        recordCurrentScrollOffset(requireAttachedWindow: false)
        persistScrollOffset()
        isDetached = true
        // 被切断的手势收不到结束通知；不清掉的话挂回后会一直当作实时滚动，跳过锚点恢复。
        isLiveScrolling = false
        hover.forgetHoveredItem()
        actions = .inert
    }

    /// 系统内存压力时由保活容器调用；卡片正显示的图不受影响。
    func releaseHeldImages() {
        images.release()
    }

    private func makeScrollView() -> NSScrollView {
        hasMadeScrollView = true
        collectionView.collectionViewLayout = layout
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.onActivateSelection = { [weak self] id in
            self?.activate(id)
        }
        collectionView.cardMenu = { [weak self] id in
            guard let self, !self.isReset, let card = self.contents[id] else { return nil }
            return self.actions.cardMenu(card)
        }
        collectionView.register(
            Kind.Item.self,
            forItemWithIdentifier: Kind.Item.reuseIdentifier
        )

        dataSource = NativeCardDataSource<Kind.Item>.make(
            collectionView: collectionView,
            presentation: { [weak self] id in self?.contents[id] },
            configure: { [weak self] item, presentation in
                self?.configure(item, with: presentation)
            },
            showsKeyboardSelection: { [weak collectionView] in
                collectionView?.showsKeyboardSelection == true
            }
        )

        // clip view 先于 document 装上：document 装进去时就挂在补建卡片的 clip view 下。
        scrollView.contentView = clipView
        scrollView.documentView = collectionView
        // 装饰在 clip view 换好之后装上：「返回顶部」按钮要叠在 clip view 之上。
        decorationHost.attach(collectionView: collectionView, scrollView: scrollView)
        decorationHost.onScrollToTop = { [weak self] in self?.scrollToTopFromButton() }
        scrollView.onLayoutDecorations = { [weak self] in self?.decorationHost.layout() }
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.onWillLeaveWindow = { [weak self] in
            guard let self, self.isRetained, !self.isReset else { return }
            self.images.hold(self.collectionView.visibleCardItems)
        }
        scrollView.onViewportLayout = { [weak self] in
            // 重排 document 中途的 tile 不嵌套处理，视口在重排中又变了由 `resizeDocument` 自己再排一遍。
            guard let self, !self.isResizingDocument, self.pendingViewportChange.any
            else { return }
            self.resizeDocument()
            self.restorePendingOffsetIfPossible()
            self.viewportDidChange()
        }
        scrollView.onContentInsetsChange = { [weak self] oldInsets, newInsets in
            self?.contentInsetsDidChange(from: oldInsets, to: newInsets)
        }
        collectionView.setAccessibilityLabel(accessibilityLabel)

        observers.observeScrolling(of: scrollView) { [weak self] in self?.didScroll() }
        observers.observe(
            NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        ) { [weak self] in
            self?.isLiveScrolling = false
            self?.persistScrollOffset()
        }
        observers.observe(
            NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        ) { [weak self] in
            self?.isLiveScrolling = true
            self?.nearEndPagination.releaseBackpressure()
        }
        observers.observeAccessibilityDisplayOptions { [weak collectionView] in
            collectionView?.refreshVisibleCardAppearance()
        }

        applySnapshot()
        // 返回时滚动视图还没装进 SwiftUI 的层级；下一轮再排版、恢复位置并判断翻页。
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isDetached else { return }
            self.resizeDocument()
            self.restorePendingOffsetIfPossible()
            self.viewportDidChange()
        }
        return scrollView
    }

    func reset() {
        guard !isReset else { return }
        recordCurrentScrollOffset(requireAttachedWindow: false)
        persistScrollOffset()
        isReset = true
        decorationHost.reset()
        images.release()
        hover.forgetHoveredItem()
        for item in collectionView.visibleCardItems { item.invalidate() }
        collectionView.onActivateSelection = nil
        collectionView.cardMenu = nil
        scrollView.onViewportLayout = nil
        scrollView.onContentInsetsChange = nil
        collectionView.delegate = nil
        collectionView.dataSource = nil
        dataSource = nil
        observers.removeAll()
        onScroll = { _ in }
        onAcknowledgeScrollReset = { _ in }
        actions = .inert
        lastViewportSize = nil
        contents = NativeCardContents()
        nearEndPagination.reset()
        viewportAnchor = nil
    }
}
