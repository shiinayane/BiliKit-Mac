import Testing

@testable import BiliKit

/// 画中画结束时区分「关闭」与「还原」，「还原」等宿主回到窗口才回答 AVKit。
///
/// 依赖 AVKit 的回调顺序：点「还原」时先调 restore、再报画中画已结束，点「关闭」时只报结束（签名开发版上实测）。
@MainActor
struct PlayerPictureInPictureTests {
    @Test
    func closingWithoutRestoreIsReportedButRestoringIsNot() {
        let pictureInPicture = PlayerPictureInPicture()
        var stopsWithoutRestore = 0
        pictureInPicture.onRestore = { true }
        pictureInPicture.onStopWithoutRestore = { stopsWithoutRestore += 1 }

        pictureInPicture.didStart()
        pictureInPicture.restore(hostIsInWindow: true) { _ in }
        pictureInPicture.didStop()
        #expect(stopsWithoutRestore == 0)

        pictureInPicture.didStart()
        pictureInPicture.didStop()
        #expect(stopsWithoutRestore == 1)
        #expect(!pictureInPicture.isActive)
    }

    /// 宿主还不在窗口时等它回来再答已还原；上一次还没答的「还原」被新的取代时答没能还原，不会一直挂着。
    @Test
    func restoreIsAnsweredWhenTheHostReturnsToTheWindow() {
        let pictureInPicture = PlayerPictureInPicture()
        pictureInPicture.onRestore = { true }
        var answers: [String] = []

        pictureInPicture.restore(hostIsInWindow: false) { answers.append("first:\($0)") }
        #expect(answers.isEmpty)
        pictureInPicture.restore(hostIsInWindow: false) { answers.append("second:\($0)") }
        pictureInPicture.hostDidEnterWindow()
        pictureInPicture.hostDidEnterWindow()

        #expect(answers == ["first:false", "second:true"])
    }
}
