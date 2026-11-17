/// 会自己消失的提示停留多久：写入结果胶囊（`AccountWriteCoordinator`）与播放器顶部的反馈徽标共用这一处。
///
/// 一条提示是哪一档由它的种类决定（写入结果带不带网页回退，播放器反馈是回显还是说明），这里只给每档的时长。会停留到
/// 下一次操作的失败说明（刷新、分页、输入框）与常驻状态不走这里。
enum TransientNoticePolicy {
    /// 按键回显（进退、音量、开关、拷贝）停留的时长。
    ///
    /// 只确认按键被接收，看一眼就够；调长更久遮挡画面，连按时也更容易盖住下一条，调短来不及看清。
    static let echoDuration: Duration = .milliseconds(800)
    /// 一句话的说明（写入结果、登录后可…、接着播放…）停留的时长。
    ///
    /// 够读完两行；读屏另有通告，不依赖停留。调长会让连续操作时旧说明盖住新内容更久。
    static let messageDuration: Duration = .seconds(4)
    /// 带「在浏览器中打开」的写入结果停留的时长（`AccountWriteReport.webFallbackURL`）。
    ///
    /// 要留出读完说明、再把指针移过去点按的时间；调短来不及点，调长会久久盖住相关推荐。
    static let actionableMessageDuration: Duration = .seconds(8)
}
