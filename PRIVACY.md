# BiliKit 隐私说明

生效状态：V1 发布前草案
最近更新：2026-08-24

BiliKit 是开源、非官方的 macOS Bilibili 客户端。当前版本没有 BiliKit 自建账号、分析后台、广告
SDK、跨 App 跟踪或自动上传的崩溃收集服务；项目维护者不会通过 BiliKit 自有服务器收集用户的
观看内容、登录 Cookie 或设备标识。

## 与 Bilibili 的直接通信

BiliKit 会从用户的 Mac 直接连接 Bilibili 的登录、API、图片、字幕和媒体服务，以提供二维码登录、
浏览、观看历史读取和视频播放。与任何网络请求一样，服务提供方会看到完成请求所必需的 IP 地址、
时间及标准网络元数据；登录后，只有明确允许的只读账户 API 请求可以携带 Cookie。媒体 CDN、图片、
字幕正文和本机 loopback 播放请求不会取得 BiliKit 的认证授权器。

Bilibili 对其服务端数据的处理不由 BiliKit 控制，适用其自身的服务条款和隐私政策。BiliKit 不承诺
未公开接口长期稳定，也不通过区域解锁、DRM 绕过或权限规避扩大服务端授权。

## 登录凭据

- 二维码 key、完整登录 URL 和候选 Cookie 只在登录流程的短生命周期内存中存在；
- 登录成功且会话验证通过后，版本化 Cookie 凭据才写入 Data Protection Keychain；
- Keychain item 仅限本机、设备解锁时可访问，不启用同步；
- Cookie 不进入 UserDefaults、日志、fixture、截图或仓库；
- 应用内退出登录会取消相关会话并删除 Keychain item。删除失败时会明确报告失败。

仅删除 App 不保证 macOS 同时删除 Keychain item，因此永久卸载前应先在应用内退出登录。

## 本机偏好与临时内容

UserDefaults 只保存非内容偏好，例如音量、静音、倍速、弹幕显示参数、播放线路选择和实验性响度
均一化开关。BiliKit 不在 UserDefaults 中保存 Cookie、视频 BVID/CID、标题、完整 URL、字幕／弹幕
正文或播放位置。

当前 V1 不建立观看内容的持久化数据库。页面结果、字幕、弹幕、播放地址、线路测速样本和播放位置
只在当前进程或对应会话内存中保留，并在切换内容、取消、登出或 owner 销毁时按职责清理。图片和
媒体使用无凭据的临时网络会话或有界内存缓存，不建立通用磁盘内容缓存。

## 日志、诊断与隐私清单

BiliKit 的生产日志不得记录 Cookie、token、二维码 key、完整认证／媒体 URL、用户身份、标题、字幕
或弹幕正文。App 不自动把日志或崩溃报告上传给项目维护者；用户主动提交 issue 前仍应检查附件和
截图，避免包含账号、二维码或观看内容。

App bundle 包含 Apple Privacy Manifest，用 required-reason API 声明 UserDefaults 的应用内偏好用途。
公证只验证签名和恶意内容风险，不替代本隐私说明或服务端隐私政策。

## 联系与变更

一般隐私问题可通过 [GitHub Issues](https://github.com/shiinayane/BiliKit-Mac/issues) 提出；涉及凭据、
可利用漏洞或其他不适合公开的信息不得提交公开 issue，私密渠道的当前状态见
[`SECURITY.md`](./SECURITY.md)。如果未来增加遥测、自建服务、持久化观看数据或新的凭据用途，
必须在发布前更新本文、Privacy Manifest、相关安全文档和用户界面说明。
