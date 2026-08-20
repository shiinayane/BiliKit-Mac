# BiliKit App Icon v1

本目录保存 BiliKit v1 App Icon 的几何源文件。实际构建输入以及可继续编辑的
Icon Composer 文档位于 `BiliKitMac/AppIcon.icon`。

> [!IMPORTANT]
> 本目录及 `BiliKitMac/AppIcon.icon` 中的品牌资产不属于仓库 MIT 授权范围。
> Copyright © 2026 shiinayane。保留所有权利。具体允许与限制见
> [BiliKit 品牌资产权利声明](../../../BRAND-ASSETS.md)。

## 图稿约定

- 画布为 1024 × 1024，背景透明。
- SVG 中不烘焙外框遮罩、背景、Liquid Glass、高光、折射、模糊或阴影。
- SVG 使用明确的 Display P3 色值：
  - 珊瑚色 K 双臂：`color(display-p3 1.0000 0.3765 0.4784)`，回退色为
    `#FF607A`。
  - 蓝色前景：`color(display-p3 0.0980 0.3608 1.0000)`，回退色为
    `#195CFF`。
- 在 Icon Composer 中替换素材时，必须保留三份 SVG 的完整画布坐标系。

## 图层顺序

Icon Composer 中的分组从后向前依次为：

1. `Coral K Underlay`
   - `01-k-lower-underlay.svg`
   - `02-k-upper-underlay.svg`
   - 光照模式：Combined
2. `Blue Foreground`
   - `03-blue-foreground.svg`

K 的两条斜臂有意共用同一个分组和材质设置。纳入版本控制的 `.icon` 文档是 v1
背景、Liquid Glass、透明度、阴影、外观模式和平台配置的唯一权威来源。

## 编辑流程

1. 后续版本如需修改已经锁定的几何，先复制整个 v1 目录。
2. 使用矢量编辑器修改 SVG 几何，不得裁剪 1024 × 1024 画布。
3. 使用 Icon Composer 替换 `BiliKitMac/AppIcon.icon` 中对应的图像。
4. 分别以大、小预览尺寸检查 Default、Dark 和 Mono 外观。
5. 构建 App，并在 Finder、Dock、Launchpad 和“关于”面板中检查实际渲染结果。

## 宣传图导出

以下 PNG 均直接从 Icon Composer 导出：

- `Marketing/BiliKit-AppIcon-Default-1024.png`：1024 × 1024 宣传母版。
- `Marketing/BiliKit-AppIcon-Default-256.png`：Default 外观的 256 × 256 轻量版本。
- `Marketing/BiliKit-AppIcon-Dark-256.png`：Dark 外观的 256 × 256 轻量版本。

两个轻量版本在仓库 README 中并列展示，也可用于其他小尺寸宣传场景。

共同参数如下：

- 平台：iOS、macOS
- 比例：1×
- 光照角度：-45°
- 色彩配置：Display P3

修改任何 Icon Composer 材质或外观设置后，都应从 `BiliKitMac/AppIcon.icon` 重新导出
这些 PNG。不要直接合并原始 SVG 图层来重建宣传图，否则会丢失系统渲染的材质效果。
