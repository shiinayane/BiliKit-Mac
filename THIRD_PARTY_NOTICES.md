# 第三方声明

项目当前不打包第三方视觉资产，并使用以下源码 Package：

## SwiftProtobuf

- 版本：精确固定为 1.38.1（revision `55d7a1cc5666b85c13464aea1c4b4a90feccb4c8`）
- 来源：https://github.com/apple/swift-protobuf
- 许可证：Apache License 2.0 with Runtime Library Exception
- 用途：仅由 `BiliAPI` 解码点播弹幕 protobuf wire 数据；生成器与 runtime 使用同一版本
- 许可证全文：https://github.com/apple/swift-protobuf/blob/1.38.1/LICENSE.txt

项目通过平台 SDK 使用 Apple 系统 framework，但本仓库不重新分发这些 framework。引入其他源码依赖或随包二进制前，必须在本文记录其名称、锁定版本、来源 URL、许可证、版权声明和分发义务。

`docs/RESEARCH-native-macos-client.md` 中列出的研究仓库仅作为参考。其代码、注释、fixture、图标及其他受版权保护的资产均不属于 BiliKit。
