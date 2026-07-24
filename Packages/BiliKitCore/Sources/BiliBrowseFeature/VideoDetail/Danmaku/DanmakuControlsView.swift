import SwiftUI

struct DanmakuControlsView: View {
    let model: DanmakuControlsViewModel

    var body: some View {
        HStack(spacing: 16) {
            Toggle(
                "弹幕",
                isOn: Binding(
                    get: { model.isEnabled },
                    set: { model.setEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .accessibilityIdentifier("danmaku.enabled")

            Menu("显示类型") {
                Toggle(
                    "滚动",
                    isOn: Binding(
                        get: { model.showsScrolling },
                        set: { model.setShowsScrolling($0) }
                    )
                )
                Toggle(
                    "顶部",
                    isOn: Binding(
                        get: { model.showsTop },
                        set: { model.setShowsTop($0) }
                    )
                )
                Toggle(
                    "底部",
                    isOn: Binding(
                        get: { model.showsBottom },
                        set: { model.setShowsBottom($0) }
                    )
                )
            }
            .disabled(!model.isEnabled)
            .accessibilityIdentifier("danmaku.modes")

            Spacer()
        }
        .font(.title3)
    }
}
