# BiliKit App Icon v2

本目录保存 BiliKit v2 App Icon 的几何源文件。实际构建输入以及可继续编辑的
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

## 几何约定

- 蓝色播放三角的三个圆角是连续曲率圆角：每个角由“过渡三次贝塞尔 + 圆弧 + 过渡三次贝塞尔”组成。
  过渡段的前三个控制点落在直边上，所以接直边处曲率为 0，再单调增大到圆弧的曲率，轮廓上没有
  曲率突变。过渡段转过的角度是该角总转角的 20%（平滑度 0.4），左侧两角圆弧半径约 59.6，
  尖端约 34.4；半径按“切掉的面积与同位置的相切圆弧圆角相等”求得，因此圆角的视觉大小不随平滑度变化。
  平滑度再大，锐角的左上角会收成水滴形。三角以 y = 512 上下镜像对称。
- 珊瑚色两臂是两端为正半圆（半径 85，等于半宽）的胶囊，不做连续曲率：端头宽度固定，
  加过渡段只会把弯折压短，胶囊读成方头圆角矩形，和三角的柔和感冲突。
- 珊瑚色两臂内侧边的交点（K 的凹口）位于蓝色尖端顶点左侧 14px，让尖端顶进凹口。
  恰好相切会读成偶然碰到；留缝则会在尖端右侧露出一条珊瑚色细条，小尺寸下糊成一团。
- 蓝色与珊瑚色合起来的外接框水平居中于 x = 512。

## 图层顺序

Icon Composer 中的分组从后向前依次为：

1. `Coral K Underlay`
   - `01-k-lower-underlay.svg`
   - `02-k-upper-underlay.svg`
   - 光照模式：Combined
2. `Blue Foreground`
   - `03-blue-foreground.svg`

K 的两条斜臂有意共用同一个分组和材质设置。纳入版本控制的 `.icon` 文档是 v2
背景、Liquid Glass、透明度、阴影、外观模式和平台配置的唯一权威来源。

## 编辑流程

1. 后续版本如需修改已经锁定的几何，先复制整个当前版本目录。
2. 使用矢量编辑器修改 SVG 几何，不得裁剪 1024 × 1024 画布。
3. 使用 Icon Composer 替换 `BiliKitMac/AppIcon.icon` 中对应的图像。
4. 分别以大、小预览尺寸检查 Default、Dark 和 Mono 外观。
5. 构建 App，并在 Finder、Dock、Launchpad 和“关于”面板中检查实际渲染结果。

## 宣传图导出

以下 PNG 均用 Xcode 自带的 `ictool`（Icon Composer 的命令行版本）从
`BiliKitMac/AppIcon.icon` 导出：

- `Marketing/BiliKit-AppIcon-Default-1024.png`：1024 × 1024 宣传母版。
- `Marketing/BiliKit-AppIcon-Default-256.png`：Default 外观的 256 × 256 轻量版本。
- `Marketing/BiliKit-AppIcon-Dark-256.png`：Dark 外观的 256 × 256 轻量版本。

两个轻量版本在仓库 README 中并列展示，也可用于其他小尺寸宣传场景。

共同参数为平台 macOS、比例 1×、`--design-generation 27`，输出为 Display P3。generation 27 是
`ictool` 的默认值，也是 macOS 27 的 Finder 与 Dock 实时渲染 App 图标时用的材质；generation 26
的玻璃边更厚、阴影更散，和用户实际看到的不一致。构建产物里的 `AppIcon.icns` 是 26 风格的预渲染图，
不能用来判断系统里的样子。命令里仍显式写出 generation，免得 Xcode 更新默认值后
悄悄换了材质。以 Default 1024 为例，Dark 版本把 `--rendition` 换成 `Dark`：

```sh
ictool="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
"$ictool" BiliKitMac/AppIcon.icon --export-image \
  --output-file Design/AppIcon/v2/Marketing/BiliKit-AppIcon-Default-1024.png \
  --platform macOS --rendition Default --width 1024 --height 1024 --scale 1 \
  --design-generation 27
```

修改任何 Icon Composer 材质或外观设置后，都应从 `BiliKitMac/AppIcon.icon` 重新导出
这些 PNG。不要直接合并原始 SVG 图层来重建宣传图，否则会丢失系统渲染的材质效果。
