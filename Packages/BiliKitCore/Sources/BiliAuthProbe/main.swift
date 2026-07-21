import AppKit
import BiliAuth
import Foundation

@main
enum BiliAuthProbe {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let mode: ProbeMode
        switch arguments {
        case []:
            mode = .interactive
        case ["--generate-only"]:
            mode = .generateOnly
        case ["--observe-expiry"]:
            mode = .observeExpiry
        default:
            FileHandle.standardError.write(
                Data("用法：BiliAuthProbe [--generate-only|--observe-expiry]\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
        let application = NSApplication.shared
        let delegate = ProbeAppDelegate(mode: mode)
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

private enum ProbeMode: Equatable {
    case interactive
    case generateOnly
    case observeExpiry
}

@MainActor
private final class ProbeAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let session = WebQRLoginSession()
    private let mode: ProbeMode
    private var task: Task<Void, Never>?
    private var window: NSWindow?

    init(mode: ProbeMode) {
        self.mode = mode
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

            if mode == .generateOnly {
                _ = try qrCode.makeCGImage(scale: 2)
                print("state=qr-generated qr-host=\(qrCode.host)")
                await session.cancel()
                closeAndExit(EXIT_SUCCESS)
                return
            }

            if mode == .interactive {
                try show(qrCode)
                print("state=awaiting-scan qr-host=\(qrCode.host)")
            } else {
                print("state=awaiting-expiry qr-host=\(qrCode.host)")
            }

            let timeoutSeconds = mode == .observeExpiry ? 240 : 180
            let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
            var reportedAwaitingConfirmation = false
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .seconds(2))
                let state = try await session.pollOnce()
                switch state {
                case .awaitingScan:
                    continue
                case .awaitingConfirmation:
                    if mode == .observeExpiry {
                        await finish(with: state, exitCode: EXIT_FAILURE)
                        return
                    }
                    if !reportedAwaitingConfirmation {
                        print("state=awaiting-confirmation")
                        reportedAwaitingConfirmation = true
                    }
                    continue
                case let .awaitingCredentialValidation(observation):
                    print("state=awaiting-credential-validation")
                    printObservation(observation)
                    let isLoggedIn = try await session.validatePendingCredential()
                    print("credential-validation-is-login=\(isLoggedIn)")
                    await session.cancel()
                    closeAndExit(isLoggedIn ? EXIT_SUCCESS : EXIT_FAILURE)
                    return
                case .expired where mode == .observeExpiry:
                    print("state=expired")
                    await session.cancel()
                    closeAndExit(EXIT_SUCCESS)
                    return
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
        if case let .failed(.unsupportedStatus(observation)) = state {
            printObservation(observation)
        }
        await session.cancel()
        closeAndExit(exitCode)
    }

    private func printObservation(_ observation: WebQRStatusObservation) {
        print("data-fields=\(joined(observation.dataFieldNames))")
        print("url-scheme=\(observation.urlScheme ?? "none")")
        print("url-host=\(observation.urlHost ?? "none")")
        print("url-query-names=\(joined(observation.urlQueryNames))")
        print("refresh-token-present=\(observation.refreshTokenPresent)")
        print("response-header-names=\(joined(observation.responseHeaderNames))")
        print("cookie-names=\(joined(observation.cookieNames))")
        print("cookie-attribute-names=\(joined(observation.cookieAttributeNames))")
        for cookie in observation.cookies {
            print(
                "cookie-metadata="
                    + "name:\(cookie.name),"
                    + "domain:\(cookie.domain),"
                    + "path:\(cookie.path),"
                    + "secure:\(cookie.isSecure),"
                    + "http-only:\(cookie.isHTTPOnly),"
                    + "session-only:\(cookie.isSessionOnly),"
                    + "has-expiry:\(cookie.hasExpiry)"
            )
        }
    }

    private func joined(_ values: [String]) -> String {
        values.isEmpty ? "none" : values.joined(separator: ",")
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
