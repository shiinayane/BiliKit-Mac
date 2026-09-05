# 第三方声明

项目当前不打包第三方视觉资产，并使用以下第三方依赖：

## SwiftProtobuf

- 版本：精确固定为 1.38.1（revision `55d7a1cc5666b85c13464aea1c4b4a90feccb4c8`）
- 来源：https://github.com/apple/swift-protobuf
- 许可证：Apache License 2.0 with Runtime Library Exception
- 用途：仅由 `BiliAPI` 解码点播弹幕 protobuf wire 数据；生成器与 runtime 使用同一版本
- 许可证全文：https://github.com/apple/swift-protobuf/blob/1.38.1/LICENSE.txt

项目通过平台 SDK 使用 Apple 系统 framework，但本仓库不重新分发这些 framework。引入其他源码依赖或随包二进制前，必须在本文记录其名称、锁定版本、来源 URL、许可证、版权声明和分发义务。

本地 `references/` 中的第三方研究 checkout 仅作为参考。其代码、注释、fixture、图标及其他
受版权保护的资产均不属于 BiliKit，也不得进入产品、测试 fixture 或发布物。

## Sparkle

- 版本：精确固定为 2.9.6（revision `ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a`）
- 来源：https://github.com/sparkle-project/Sparkle/tree/2.9.6
- 用途：仅 App target 的标准自动更新 UI、下载、验签及 Installer XPC 安装。
- 许可证：MIT；分发包同时包含 bsdiff、sais-lite、Ed25519 与 SUSignatureVerifier 的附属许可。
- 版权、全部许可条件与免责声明原文随 App 资源打包：
  [`Sparkle-LICENSE.txt`](BiliKitMac/Resources/Licenses/Sparkle-LICENSE.txt)。发布时保留该文件与 framework 自带资源。
- SwiftPM 二进制 checksum：`8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606`。
