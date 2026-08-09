import BiliApplication
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

            Picker(
                "滚动速度",
                selection: Binding(
                    get: { model.speedLevel },
                    set: { model.setSpeedLevel($0) }
                )
            ) {
                ForEach(DanmakuSpeedLevel.allCases, id: \.rawValue) { level in
                    Text("Lv\(level.rawValue)").tag(level)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)
            .disabled(!model.isEnabled || !model.showsScrolling)
            .accessibilityIdentifier("danmaku.speed")

            Spacer()
        }
        .font(.title3)
    }
}
