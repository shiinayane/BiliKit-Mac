import Foundation
import Testing

/// 测试用的一次性 UserDefaults：suite 名取临时目录里的绝对 plist 路径，`discard()` 清空域并删除该目录。
///
/// 不用 `BiliKitMacTests.<UUID>` 这类域名 suite：域只要写过一次，cfprefsd 就会在进程退出时把它写回
/// `~/Library/Preferences/<suite>.plist`，`removePersistentDomain` 和进程内删文件都挡不住，每次运行留下一个空 plist。
/// 绝对路径 suite 落在该路径上；目录删掉后 cfprefsd 迟到的写回找不到目录，不留下任何文件。
/// 每个实例一个新路径，并行测试之间不共享域，也不碰真实偏好。
struct ScratchDefaults {
    let defaults: UserDefaults
    private let suiteName: String
    private let directory: URL

    /// 临时目录建不出或系统拒绝该 suite 名时返回 nil，不留下目录。
    init?() {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "BiliKitMacTests.defaults.\(UUID().uuidString)",
            isDirectory: true
        )
        let suiteName = directory.appendingPathComponent("defaults.plist").path
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            try? fileManager.removeItem(at: directory)
            return nil
        }
        self.defaults = defaults
        self.suiteName = suiteName
        self.directory = directory
    }

    /// 先清空 cfprefsd 里的域，再删目录；之后的写入不再落盘。
    func discard() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// 在一次性的 UserDefaults 中执行，结束后丢弃；测试之间、测试与真实偏好互不影响。
func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    guard let scratch = ScratchDefaults() else {
        Issue.record("无法创建隔离的 UserDefaults")
        return
    }
    defer { scratch.discard() }
    try body(scratch.defaults)
}
