import AppKit

extension NSColor {
    /// 按给定外观解析出的 CGColor。
    ///
    /// `cgColor` 按“当前绘制外观”取值并就此定格；在事件回调或外观变化通知里，当前绘制外观未必是
    /// 视图自己的外观。写进 layer 的动态颜色都经由这里解析，并在外观变化时重新写入。
    package func cgColor(for appearance: NSAppearance) -> CGColor {
        var resolved: CGColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = cgColor
        }
        return resolved ?? cgColor
    }

    /// 换了透明度、仍随外观变化的颜色。
    ///
    /// 系统语义色（`labelColor`、`controlAccentColor`、`systemPink` 等）的 `withAlphaComponent` 按调用那一刻的
    /// 当前绘制外观取值，得到的是定格的静态颜色：存下来的颜色在明暗切换后仍是旧外观的颜色，`cgColor(for:)`
    /// 也救不回来。半透明的语义色都经由这里派生，每次解析时按目标外观重新取底色。
    package func withDynamicAlpha(_ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved = self
            appearance.performAsCurrentDrawingAppearance {
                resolved = self.withAlphaComponent(alpha)
            }
            return resolved
        }
    }
}
