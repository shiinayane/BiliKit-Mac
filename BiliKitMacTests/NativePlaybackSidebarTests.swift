import AppKit
import BiliApplication
import BiliBrowseFeature
import BiliModels
import Foundation
import Testing

@testable import BiliKit

struct NativePlaybackSidebarTests {
    @Test
    @MainActor
    func snapshotKeepsStableSemanticSectionsAndRows() {
        let presentation = presentation(bvid: "BVCurrent")

        #expect(
            presentation.sections.map(\.id)
                == [.uploader, .summary, .selection, .comments]
        )
        #expect(
            presentation.itemIDs
                == [
                    .uploader(bvid: "BVCurrent"),
                    .summary(bvid: "BVCurrent"),
                    .selection(bvid: "BVCurrent"),
                    .commentsUnavailable(bvid: "BVCurrent"),
                ]
        )
    }

    @Test
    @MainActor
    func rootOwnsExactlyOneVerticalScrollChainWithoutHostingViews() {
        let controller = NativePlaybackSidebarController()
        controller.update(
            presentation: presentation(bvid: "BVCurrent"),
            actions: actions
        )

        let descendants = descendants(of: controller.rootView)
        let verticalScrollViews = descendants.compactMap { $0 as? NSScrollView }
            .filter(\.hasVerticalScroller)
        let hostingViews = descendants.filter {
            String(describing: type(of: $0)).contains("NSHostingView")
        }

        #expect(controller.rootView.scrollView.documentView is NSCollectionView)
        #expect(verticalScrollViews.count == 1)
        #expect(hostingViews.isEmpty)
        #expect(controller.rootView.overlayView.isFlipped)

        controller.tearDown()

        #expect(controller.rootView.scrollView.documentView == nil)
    }

    @Test
    @MainActor
    func summaryUsesSelectableNonScrollingTextKitAtSidebarWidths() throws {
        let text = String(
            repeating: "这是一段需要按字符精确换行的简介，后续链接拦截也由同一个TextKit正文视图承担。",
            count: 3
        )
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let heights = [440.0, 480.0, 520.0].map { sidebarWidth in
            NativePlaybackSidebarTextLayout.height(
                text,
                width: sidebarWidth - NativePlaybackSidebarLayout.contentInset * 2,
                font: font
            )
        }
        let textView = NativePlaybackSidebarReadOnlyTextView(font: font)
        textView.frame = NSRect(x: 0, y: 0, width: 408, height: heights[0])
        textView.setText(text, font: font, color: .secondaryLabelColor)
        textView.layoutSubtreeIfNeeded()
        let container = try #require(textView.textContainer)
        let manager = try #require(textView.layoutManager)
        manager.ensureLayout(for: container)

        #expect(heights[0] >= heights[1])
        #expect(heights[1] >= heights[2])
        #expect(heights[0] > heights[2])
        #expect(textView.isSelectable)
        #expect(!textView.isEditable)
        #expect(textView.enclosingScrollView == nil)
        #expect(textView.textContainer?.lineBreakMode == .byCharWrapping)
        #expect(container.containerSize.height == CGFloat.greatestFiniteMagnitude)
        #expect(manager.usedRect(for: container).height > 0)
    }

    @Test
    @MainActor
    func summaryKeepsItsTitleStaticAndCollapsesOnlyOverflowingBodyToFiveLines() throws {
        let summary = String(
            repeating: "简介正文需要由 TextKit 精确换行，并在超过五行时才提供展开控制。",
            count: 8
        )
        let width: CGFloat = 240
        let collapsedHeight = NativePlaybackSidebarItemMeasurement.summary(
            summary,
            width: width,
            expanded: false
        )
        let expandedHeight = NativePlaybackSidebarItemMeasurement.summary(
            summary,
            width: width,
            expanded: true
        )
        let item = NativePlaybackSidebarSummaryItem()
        item.view.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: collapsedHeight
        )
        var toggled = false
        item.configure(summary: summary, expanded: false) {
            toggled = true
        }
        item.view.layoutSubtreeIfNeeded()

        let views = descendants(of: item.view)
        let body = try #require(views.compactMap { $0 as? NSTextView }.first)
        let expandButton = try #require(
            views.compactMap { $0 as? NSButton }.first { $0.title == "展开" }
        )
        let title = try #require(
            views.compactMap { $0 as? NSTextField }.first { $0.stringValue == "简介" }
        )

        #expect(expandedHeight > collapsedHeight)
        #expect(body.textContainer?.maximumNumberOfLines == 5)
        #expect(body.textContainer?.lineBreakMode == .byTruncatingTail)
        #expect(title.isEnabled)
        #expect(views.compactMap { $0 as? NSButton }.allSatisfy { $0.title != "简介" })
        expandButton.performClick(nil)
        #expect(toggled)

        let shortItem = NativePlaybackSidebarSummaryItem()
        shortItem.view.frame = NSRect(x: 0, y: 0, width: width, height: 80)
        shortItem.configure(summary: "不足五行的简介", expanded: false, onToggle: {})
        shortItem.view.layoutSubtreeIfNeeded()
        #expect(
            descendants(of: shortItem.view).compactMap { $0 as? NSButton }
                .allSatisfy { $0.isHidden }
        )
    }

    @Test
    @MainActor
    func blockingOverlayDoesNotOwnAFullSidebarBackdrop() {
        let overlay = NativePlaybackSidebarOverlayView()
        let views: [NSView] = [overlay] + descendants(of: overlay)

        #expect(!overlay.isOpaque)
        #expect(overlay.layer?.backgroundColor == nil)
        #expect(views.compactMap { $0 as? NSVisualEffectView }.isEmpty)
    }

    @Test
    @MainActor
    func blockingOverlayKeepsTheTransparentScrollSurfaceAndHidesOnlyItsRows() {
        let controller = NativePlaybackSidebarController()
        let loaded = presentation(bvid: "BVCurrent")
        controller.update(presentation: loaded, actions: actions)

        #expect(!controller.rootView.scrollView.isHidden)
        #expect(controller.rootView.scrollView.documentView?.isHidden == false)
        #expect(controller.rootView.overlayView.isHidden)

        controller.update(
            presentation: NativePlaybackSidebarPresentation(
                content: loaded.content,
                overlay: .loading(label: "正在加载视频上下文")
            ),
            actions: actions
        )

        #expect(!controller.rootView.scrollView.isHidden)
        #expect(controller.rootView.scrollView.documentView?.isHidden == true)
        #expect(!controller.rootView.overlayView.isHidden)
        #expect(!controller.rootView.overlayView.isOpaque)

        controller.tearDown()
    }

    @Test
    @MainActor
    func retainedFailedPageKeepsSelectionAvailableAsARecoveryPath() {
        let context = context(bvid: "BVCurrent")
        let failure = GuestVideoFailure.playback

        #expect(
            NativePlaybackSidebarOverlay.resolve(
                state: .failedPage(
                    context: context,
                    targetPage: context.pages[1],
                    failure: failure
                ),
                hasPresentedContent: true
            ) == .none
        )
    }

    @Test
    @MainActor
    func presentationReloadsOnlyTheStableRowWhoseContentChanged() throws {
        let original = presentation(bvid: "BVCurrent")
        let content = try #require(original.content)
        let updatedUploader = NativePlaybackSidebarPresentation(
            content: NativePlaybackSidebarContent(
                bvid: content.bvid,
                uploader: VideoUploaderHeaderContent(
                    owner: VideoOwner(id: 1, name: "UP 主", signature: "新签名")
                ),
                summary: content.summary,
                selection: content.selection
            ),
            overlay: .none
        )
        let overlayOnly = NativePlaybackSidebarPresentation(
            content: content,
            overlay: .loading(label: "正在加载所选视频上下文")
        )

        #expect(
            updatedUploader.changedItemIDs(comparedTo: original)
                == [.uploader(bvid: content.bvid)]
        )
        #expect(overlayOnly.changedItemIDs(comparedTo: original).isEmpty)
    }

    @Test
    @MainActor
    func blockingOverlayReleasesHiddenSidebarFirstResponder() {
        let controller = NativePlaybackSidebarController()
        controller.rootView.frame = NSRect(x: 0, y: 0, width: 440, height: 600)
        let window = NSWindow(
            contentRect: controller.rootView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.rootView
        controller.update(
            presentation: presentation(bvid: "BVCurrent"),
            actions: actions
        )
        let selectableField = NSTextField(labelWithString: "可选择的标题")
        selectableField.isSelectable = true
        controller.rootView.scrollView.documentView?.addSubview(selectableField)
        let fieldEditor = window.fieldEditor(true, for: selectableField)
        #expect(fieldEditor != nil)
        #expect(window.makeFirstResponder(fieldEditor))

        controller.update(
            presentation: NativePlaybackSidebarPresentation(
                content: presentation(bvid: "BVCurrent").content,
                overlay: .loading(label: "正在加载所选视频上下文")
            ),
            actions: actions
        )

        #expect(window.firstResponder !== fieldEditor)
        controller.tearDown()
        window.contentView = NSView()
    }

    @Test
    @MainActor
    func teardownReleasesDirectSidebarTextViewFirstResponderBeforeDetachingDocument() {
        let controller = NativePlaybackSidebarController()
        controller.rootView.frame = NSRect(x: 0, y: 0, width: 440, height: 600)
        let window = NSWindow(
            contentRect: controller.rootView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.rootView
        controller.update(
            presentation: presentation(bvid: "BVCurrent"),
            actions: actions
        )
        let textView = NSTextView()
        controller.rootView.scrollView.documentView?.addSubview(textView)
        #expect(window.makeFirstResponder(textView))

        controller.tearDown()

        #expect(window.firstResponder !== textView)
        window.contentView = NSView()
    }

    @Test
    @MainActor
    func teardownReleasesSidebarSharedFieldEditorBeforeDetachingDocument() {
        let controller = NativePlaybackSidebarController()
        controller.rootView.frame = NSRect(x: 0, y: 0, width: 440, height: 600)
        let window = NSWindow(
            contentRect: controller.rootView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.rootView
        controller.update(
            presentation: presentation(bvid: "BVCurrent"),
            actions: actions
        )
        let selectableField = NSTextField(labelWithString: "可选择的标题")
        selectableField.isSelectable = true
        controller.rootView.scrollView.documentView?.addSubview(selectableField)
        let fieldEditor = window.fieldEditor(true, for: selectableField)
        #expect(fieldEditor != nil)
        #expect(window.makeFirstResponder(fieldEditor))

        controller.tearDown()

        #expect(window.firstResponder !== fieldEditor)
        window.contentView = NSView()
    }

    @Test
    @MainActor
    func summaryAndUploaderRowsContainNativeTextViewsOnly() {
        let summaryItem = NativePlaybackSidebarSummaryItem()
        summaryItem.view.frame = NSRect(x: 0, y: 0, width: 328, height: 180)
        summaryItem.configure(summary: "可选择的简介正文", expanded: true, onToggle: {})

        let imageOwner = NativeVideoImagePipelineOwner()
        let uploaderItem = NativePlaybackSidebarUploaderItem()
        uploaderItem.view.frame = NSRect(x: 0, y: 0, width: 328, height: 64)
        uploaderItem.configure(
            content: VideoUploaderHeaderContent(
                owner: VideoOwner(id: 1, name: "UP 主", signature: "可选择的签名")
            ),
            signatureExpanded: false,
            imagePipeline: imageOwner.pipeline,
            onToggleSignature: {}
        )

        let views = descendants(of: summaryItem.view) + descendants(of: uploaderItem.view)
        let textViews = views.compactMap { $0 as? NSTextView }

        #expect(textViews.count == 2)
        #expect(textViews.allSatisfy { $0.isSelectable && !$0.isEditable })
        #expect(views.compactMap { $0 as? NSScrollView }.isEmpty)
        #expect(
            views.allSatisfy {
                !String(describing: type(of: $0)).contains("NSHostingView")
            }
        )

        uploaderItem.prepareForReuse()
        imageOwner.shutdown()
    }

    @Test
    @MainActor
    func uploaderSignatureRecomputesOverflowWhileSidebarResizes() throws {
        let signature = String(repeating: "签名", count: 16)
        let imageOwner = NativeVideoImagePipelineOwner()
        let item = NativePlaybackSidebarUploaderItem()
        item.view.frame = NSRect(x: 0, y: 0, width: 488, height: 80)
        item.configure(
            content: VideoUploaderHeaderContent(
                owner: VideoOwner(id: 1, name: "UP 主", signature: signature)
            ),
            signatureExpanded: false,
            imagePipeline: imageOwner.pipeline,
            onToggleSignature: {}
        )
        item.view.layoutSubtreeIfNeeded()
        let views = descendants(of: item.view)
        let signatureText = try #require(views.compactMap { $0 as? NSTextView }.first)
        let toggle = try #require(
            views.compactMap { $0 as? NSButton }
                .first { $0.accessibilityLabel() == "UP 主签名" }
        )

        #expect(toggle.isHidden)
        #expect(signatureText.textContainer?.maximumNumberOfLines == 0)
        signatureText.setSelectedRange(NSRange(location: 2, length: 4))

        item.view.frame.size.width = 408
        item.view.layoutSubtreeIfNeeded()

        #expect(!toggle.isHidden)
        #expect(toggle.title == "展开")
        #expect(signatureText.textContainer?.maximumNumberOfLines == 1)
        #expect(signatureText.selectedRange() == NSRange(location: 2, length: 4))

        item.prepareForReuse()
        imageOwner.shutdown()
    }

    @Test
    @MainActor
    func pageMenuKeepsAtomicCIDIntentInNativeMenuItems() {
        let projection = selectionProjection()
        let item = NativePlaybackSidebarSelectionItem()
        item.view.frame = NSRect(x: 0, y: 0, width: 328, height: 80)
        var selectedCID: Int64?
        item.configure(
            projection: projection,
            browsedSectionID: projection.selectedEpisodeSectionID,
            onSelectSection: { _ in },
            onSelectEpisode: { _ in },
            onSelectPage: { selectedCID = $0 },
            onRetryPages: {}
        )
        item.view.layoutSubtreeIfNeeded()

        let pagePopUp = descendants(of: item.view).compactMap { $0 as? NSPopUpButton }
            .first { !$0.isHidden }
        let targetItem = pagePopUp?.menu?.items.last {
            $0.representedObject is NSNumber
        }
        let sent = targetItem.flatMap { item in
            item.action.map {
                NSApplication.shared.sendAction($0, to: item.target, from: item)
            }
        }

        #expect(projection.showsPagePicker)
        #expect(pagePopUp != nil)
        #expect(sent == true)
        #expect(selectedCID == 1_002)
    }

    @Test
    @MainActor
    func sectionPickerLimitsEpisodePickerToTheBrowsedSection() throws {
        let first = collectionEpisode(
            sectionID: 10,
            episodeID: 100,
            bvid: "BVCurrent",
            title: "第一集"
        )
        let second = collectionEpisode(
            sectionID: 11,
            episodeID: 101,
            bvid: "BVOther",
            title: "幕后花絮"
        )
        let collection = VideoCollection(
            id: 1,
            title: "合集",
            reportedEpisodeCount: 2,
            sections: [
                collectionSection(id: 10, title: "正片", episodes: [first]),
                collectionSection(id: 11, title: "花絮", episodes: [second]),
            ]
        )
        let projection = selectionProjection(
            context: context(bvid: "BVCurrent", collection: collection)
        )
        let item = NativePlaybackSidebarSelectionItem()
        item.view.frame = NSRect(x: 0, y: 0, width: 328, height: 130)
        var browsedSectionID: VideoCollectionSectionIdentity?
        var selectedCID: Int64?
        item.configure(
            projection: projection,
            browsedSectionID: projection.selectedEpisodeSectionID,
            onSelectSection: { browsedSectionID = $0 },
            onSelectEpisode: { _ in },
            onSelectPage: { selectedCID = $0 },
            onRetryPages: {}
        )
        item.view.layoutSubtreeIfNeeded()

        let popUps = descendants(of: item.view).compactMap { $0 as? NSPopUpButton }
        let sectionPopUp = try #require(
            popUps.first { $0.accessibilityLabel() == "分区" }
        )
        let episodePopUp = try #require(
            popUps.first { $0.accessibilityLabel() == "选集" }
        )
        let pagePopUp = try #require(
            popUps.first { $0.accessibilityLabel() == "分 P" }
        )
        #expect(sectionPopUp.menu?.items.map(\.title) == ["正片", "花絮"])
        #expect(episodePopUp.menu?.items.map(\.title) == ["第一集"])
        #expect(!pagePopUp.isHidden)

        let targetSection = try #require(
            sectionPopUp.menu?.items.first { $0.title == "花絮" }
        )
        let sent = targetSection.action.map {
            NSApplication.shared.sendAction($0, to: targetSection.target, from: targetSection)
        }

        #expect(sent == true)
        #expect(browsedSectionID == collection.sections[1].id)
        #expect(episodePopUp.menu?.items.map(\.title) == ["请选择选集", "幕后花絮"])
        #expect(pagePopUp.isHidden)
        #expect(pagePopUp.menu == nil)
        #expect(selectedCID == nil)
    }

    @MainActor
    private var actions: NativePlaybackSidebarActions {
        NativePlaybackSidebarActions(
            retry: {},
            selectEpisode: { _ in },
            selectPage: { _, _ in },
            retryPages: {}
        )
    }

    @MainActor
    private func presentation(bvid: String) -> NativePlaybackSidebarPresentation {
        let context = context(bvid: bvid)
        return NativePlaybackSidebarPresentation(
            content: NativePlaybackSidebarContent(
                bvid: bvid,
                uploader: VideoUploaderHeaderContent(
                    owner: context.detail.owner,
                    signatureState: .loaded(context.detail.owner.signature)
                ),
                summary: context.detail.summary,
                selection: selectionProjection(context: context)
            ),
            overlay: .none
        )
    }

    @MainActor
    private func selectionProjection(
        context: GuestVideoContext? = nil
    ) -> PlaybackSelectionProjection {
        let context = context ?? self.context(bvid: "BVCurrent")
        return PlaybackSelectionProjection(
            context: context,
            selectedEpisodeID: nil,
            requestedBVID: context.detail.bvid,
            requestedCID: context.pages.first?.cid,
            presentedIdentity: nil,
            pageStates: [:],
            pagesByEpisode: [:]
        )
    }

    private func context(
        bvid: String,
        collection: VideoCollection? = nil
    ) -> GuestVideoContext {
        let pages = [
            VideoPage(cid: 1_001, index: 1, title: "第一部分", durationSeconds: 61),
            VideoPage(cid: 1_002, index: 2, title: "第二部分", durationSeconds: 122),
        ]
        return GuestVideoContext(
            detail: VideoDetail(
                bvid: bvid,
                title: "当前视频",
                summary: "一段可选择、可精确换行的简介正文。",
                coverURL: nil,
                owner: VideoOwner(id: 1, name: "UP 主", signature: "签名"),
                statistics: VideoStatistics(
                    viewCount: 1,
                    danmakuCount: 1,
                    likeCount: 1
                ),
                durationSeconds: 122,
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                pages: pages,
                collection: collection
            ),
            pages: pages,
            selectedPage: pages[0],
            playback: VideoPlayback(
                manifest: PlaybackManifest(
                    videoRepresentations: [],
                    originalAudioRepresentations: []
                ),
                mediaHeaders: [:]
            )
        )
    }

    private func collectionSection(
        id: Int64,
        title: String,
        episodes: [VideoCollectionEpisode]
    ) -> VideoCollectionSection {
        VideoCollectionSection(
            id: VideoCollectionSectionIdentity(seasonID: 1, sectionID: id),
            ordinal: Int(id - 10),
            title: title,
            episodes: episodes
        )
    }

    private func collectionEpisode(
        sectionID: Int64,
        episodeID: Int64,
        bvid: String,
        title: String
    ) -> VideoCollectionEpisode {
        VideoCollectionEpisode(
            id: VideoCollectionEpisodeIdentity(
                seasonID: 1,
                sectionID: sectionID,
                episodeID: episodeID
            ),
            ordinal: Int(episodeID - 100),
            aid: nil,
            bvid: bvid,
            title: title,
            coverURL: nil,
            durationSeconds: 122,
            defaultCID: 1_001,
            knownPages: [
                VideoPage(
                    cid: 1_001,
                    index: 1,
                    title: "第一部分",
                    durationSeconds: 61
                )
            ]
        )
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
