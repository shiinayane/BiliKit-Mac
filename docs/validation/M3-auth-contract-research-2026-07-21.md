# M3 Web QR 认证契约研究记录（2026-07-21）

> 结论：完成实现前的最小现场验证与安全边界设计；M3 登录功能尚未实现，M3 Gate 尚未关闭。

## 1. 环境与方法

- 日期：2026-07-21（Asia/Tokyo）。
- 目标主机：`passport.bilibili.com`。
- 方法：使用无 Cookie、无账号的 HTTPS 请求调用二维码生成 endpoint，再使用本次生成的临时 key 轮询一次。
- 输出限制：探针只输出 envelope code/message、字段名、类型、长度、scheme/host 和业务状态；不输出 key、完整 URL、响应体、响应头值、Cookie 或 token。
- 临时响应文件在命令完成后立即删除。

本记录是对当日运行行为的观察。未发现对应的官方公开稳定 Web API 文档，因此不能把字段和状态当作长期承诺。

## 2. 现场观察

生成 endpoint：

```text
GET https://passport.bilibili.com/x/passport-login/web/qrcode/generate
envelope.code = 0
envelope.message = OK
data keys = qrcode_key,url
qrcode_key length = 32
url scheme = https
url host = account.bilibili.com
```

立即轮询 endpoint：

```text
GET https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key=<redacted>
envelope.code = 0
envelope.message = OK
data keys = code,message,refresh_token,timestamp,url
data.code = 86101
data.message = 未扫码
refresh_token present = false
timestamp type = number
```

本次未扫码响应没有 `Set-Cookie` 响应头。这里不能推导成功响应是否通过 header、JSON URL 或两者提供认证材料。

## 3. 已确认与未确认边界

已确认：

- 两个 endpoint 当前接受匿名 GET。
- 生成结果包含临时 key 和 HTTPS 二维码 URL。
- 当前二维码 URL 主机是 `account.bilibili.com`。
- 轮询使用外层 envelope 和内层业务状态；`86101` 当前表示未扫码。
- 未扫码 payload 已包含成功流程可能使用的 `refresh_token`、`timestamp` 与 `url` 字段，但 token 当前为空。

仍未确认：

- 扫码后未确认、成功、过期、取消和风控状态的实际 code/message。
- 二维码有效期、推荐轮询间隔和服务端限流边界。
- 成功凭据来自响应 header、JSON URL 或其他位置，以及必须保留的 Cookie allowlist/属性。
- 登录态校验 endpoint 的成功/失效 contract。
- Web Cookie 是否需要配套 refresh token 才能可靠延续，以及刷新协议。

这些项目必须通过一次人工扫码的脱敏探针确认；在确认前不写真实 Keychain 持久化代码。

## 4. 第一方安全依据

- Bilibili 隐私政策说明 Cookie 会用于记住注册用户身份、分析使用与个性化，并说明会使用 SSL 等措施保护信息：<https://www.bilibili.com/blackboard/privacy-policy.html>。
- Apple Keychain Services 面向小块秘密数据的安全存储：<https://developer.apple.com/documentation/security/keychain-services/>。
- Apple 说明 ephemeral URL session 不把 cache、Cookie 或 credential 持久化到磁盘：<https://developer.apple.com/documentation/foundation/urlsessionconfiguration/ephemeral>。
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 只允许设备解锁时访问，且 item 不迁移到新设备：<https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly>。

## 5. 对实现计划的约束

1. 先以全假值 fixture 固定生成与 `86101`，未知状态必须失败关闭。
2. 增加可显式运行的脱敏人工扫码探针，输出字段结构和状态序列，不输出任何值。
3. 得到成功/过期证据后再补齐 fixture、Cookie 白名单和登录态校验。
4. 通过上述契约测试后才实现 Keychain store 和请求授权器。
5. 任何 endpoint 漂移都更新本记录或新增带日期的验证记录，不覆写历史事实。

## 6. 本次变更验证

- 本地环境：macOS 26.5.2（25F84）、Apple Silicon arm64。
- `Scripts/check-architecture.sh`：通过。
- Package：54 项测试、13 个测试套件全部通过；loopback 播放测试在允许监听 `127.0.0.1` 的环境运行。
- Markdown 相对链接：无缺失目标。
- 新增认证文档秘密模式检查：未发现形如实际 QR key、`SESSDATA`、`bili_jct` 或 `refresh_token` 值的内容。
- `git diff --check`：通过。
