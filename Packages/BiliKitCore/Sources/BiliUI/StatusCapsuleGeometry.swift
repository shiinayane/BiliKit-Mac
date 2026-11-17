import SwiftUI

/// 窗口里的状态胶囊的唯一几何来源：顶部刷新胶囊（`RefreshStatusCapsule`）、底部分页胶囊（`PaginationStatusOverlay`）与
/// 写入结果胶囊（`AccountWriteStatusCapsule`）。
package enum StatusCapsuleGeometry {
    package static let contentPadding: CGFloat = 8
    package static let spacing: CGFloat = 8
    /// 胶囊与列表边缘的距离：窄窗口下两行说明也不贴边。
    package static let horizontalInset: CGFloat = 24
    package static let bottomInset: CGFloat = 8
    package static let messageLineLimit = 2
}

extension View {
    /// 窗口里状态胶囊的外观：同一字号、内边距与材质底，三种胶囊只经这里取。
    ///
    /// 播放器画面上的提示另有一套玻璃底（App 的 `PlayerGlassCapsuleBackground`），不用这一套。
    package func statusCapsuleChrome() -> some View {
        font(.callout)
            .padding(StatusCapsuleGeometry.contentPadding)
            .background(.regularMaterial, in: Capsule())
    }
}
