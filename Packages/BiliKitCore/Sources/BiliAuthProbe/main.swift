import AppKit
import BiliAuth
import Foundation

@main
enum BiliAuthProbe {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.isEmpty || arguments == ["--generate-only"] else {
            FileHandle.standardError.write(
                Data("用法：BiliAuthProbe [--generate-only]\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
        let application = NSApplication.shared
        let delegate = ProbeAppDelegate(generateOnly: arguments == ["--generate-only"])
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
private final class ProbeAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let session = WebQRLoginSession()
    private let generateOnly: Bool
    private var task: Task<Void, Never>?
    private var window: NSWindow?

    init(generateOnly: Bool) {
        self.generateOnly = generateOnly
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        task = Task { await runProbe() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        task?.cancel()
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
    }

    private func runProbe() async {
        print("state=requesting-qr-code")
        do {
            let initialState = try await session.requestQRCode()
            guard case let .awaitingScan(qrCode) = initialState else {
                await finish(with: initialState, exitCode: EXIT_FAILURE)
                return
            }

            if generateOnly {
                _ = try qrCode.makeCGImage(scale: 2)
                print("state=qr-generated qr-host=\(qrCode.host)")
                await session.cancel()
                closeAndExit(EXIT_SUCCESS)
                return
            }

            try show(qrCode)
            print("state=awaiting-scan qr-host=\(qrCode.host)")

            let deadline = ContinuousClock.now + .seconds(180)
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .seconds(2))
                let state = try await session.pollOnce()
                switch state {
                case .awaitingScan:
                    continue
                default:
                    await finish(with: state, exitCode: EXIT_FAILURE)
                    return
                }
            }

            print("state=local-timeout")
            await session.cancel()
            closeAndExit(EXIT_FAILURE)
        } catch is CancellationError {
            await session.cancel()
            closeAndExit(EXIT_SUCCESS)
        } catch let error as WebQRCodeRenderingError {
            writeError("BiliAuthProbe failed: qr-rendering-\(error)\n")
            await session.cancel()
            closeAndExit(EXIT_FAILURE)
        } catch {
            writeError(
                "BiliAuthProbe failed: \(String(reflecting: type(of: error)))\n"
            )
            await session.cancel()
            closeAndExit(EXIT_FAILURE)
        }
    }

    private func show(_ qrCode: WebQRCode) throws {
        let cgImage = try qrCode.makeCGImage(scale: 12)
        let contentSize = NSSize(width: 360, height: 400)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "BiliKit 登录验证探针"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let contentView = NSView(frame: NSRect(origin: .zero, size: contentSize))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let imageContainer = NSView(frame: NSRect(x: 40, y: 64, width: 280, height: 280))
        imageContainer.wantsLayer = true
        imageContainer.layer?.backgroundColor = NSColor.white.cgColor

        let imageView = NSImageView(frame: NSRect(x: 16, y: 16, width: 248, height: 248))
        imageView.image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageContainer.addSubview(imageView)

        let instruction = NSTextField(labelWithString: "请使用哔哩哔哩移动端扫码。关闭窗口即可取消。")
        instruction.alignment = .center
        instruction.frame = NSRect(x: 20, y: 24, width: 320, height: 24)

        contentView.addSubview(imageContainer)
        contentView.addSubview(instruction)
        window.contentView = contentView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func finish(with state: WebQRLoginState, exitCode: Int32) async {
        print("state=\(state.description)")
        await session.cancel()
        closeAndExit(exitCode)
    }

    private func closeAndExit(_ exitCode: Int32) {
        window?.delegate = nil
        window?.close()
        window = nil
        NSApplication.shared.terminate(nil)
        exit(exitCode)
    }

    private func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}
