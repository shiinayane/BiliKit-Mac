import AppKit
import SwiftUI

@main
struct DanmakuLabApp: App {
    @NSApplicationDelegateAdaptor(DanmakuLabAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        WindowGroup("Danmaku Lab") {
            DanmakuLabView()
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 760)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
private final class DanmakuLabAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        bringLabWindowForward()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        bringLabWindowForward()
        return true
    }

    private func bringLabWindowForward() {
        DispatchQueue.main.async {
            NSApp.activate()
            NSApp.windows.first(where: \.canBecomeKey)?
                .makeKeyAndOrderFront(nil)
        }
    }
}
