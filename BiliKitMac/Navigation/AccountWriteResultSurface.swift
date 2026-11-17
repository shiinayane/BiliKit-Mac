import BiliApplication

/// 窗口的写入结果显示在哪一处。
///
/// 规则见 docs/ARCHITECTURE.md「临时提示与结果」：一次写入只在一处显示、只通告一次。
enum AccountWriteResultSurface: Equatable {
    /// 窗口详情栏底部的写入结果胶囊。
    case window
    /// 播放器画面顶部：AVKit 独立全屏时主窗口的胶囊在全屏窗口里看不到。
    case player
}

extension AccountWriteCoordinator {
    /// 窗口底部胶囊此刻显示的结果；结果显示在播放器上时为 nil。
    var windowReport: AccountWriteReport? {
        resultSurface == .window ? report : nil
    }

    /// 播放器上此刻显示的结果；结果显示在窗口底部时为 nil。
    var playerReport: AccountWriteReport? {
        resultSurface == .player ? report : nil
    }
}
