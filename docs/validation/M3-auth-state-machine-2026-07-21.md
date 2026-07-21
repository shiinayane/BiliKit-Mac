# M3 Web QR 基础状态机验证（2026-07-21）

> 结论：M3 第 2 步基础状态机与脱敏契约已实现；成功/过期协议、Cookie、Keychain 和登录 UI 尚未实现，M3 Gate 尚未关闭。

## 1. 实现范围

- 新增 `BiliAuth` library target 和由它实际驱动的 `BiliAuthProbe` executable target。
- 生产认证 transport 使用独立 `URLSessionConfiguration.ephemeral`，关闭自动 Cookie、Cookie storage 和 URL cache，设置 15 秒请求/30 秒资源超时，并拒绝 HTTP 重定向。
- `WebQRLoginSession` actor 实现二维码生成、一次轮询、取消、网络/HTTP/HTML/解码失败和未知状态处理。
- 当前只接受 2026-07-21 现场确认的 `86101` 未扫码状态；其他业务状态返回仅含 code 的 `unsupported-status`，不读取或输出服务端 message、URL、refresh token。
- 生成结果只接受 HTTPS 和 `account.bilibili.com` 精确主机；相似后缀主机会被拒绝。
- 原始 QR URL 封装在不可直接读取的 `WebQRCode` 中，由 Core Image 在内存生成图像；探针不落盘，也不打印二维码内容。
- generation/poll ID 阻止旧请求覆盖更新意图；Swift Task 取消会传播并清回 signed-out。

## 2. Fixture 与秘密边界

- 新增生成、`86101` 和未知状态三个手写 JSON fixture；二维码 key 明确使用 `FIXTURE_` 哨兵。
- 未确认的扫码成功、已扫码未确认、过期和 Cookie 不进入 fixture。
- 未知状态 fixture 使用 `TOP_SECRET_SHOULD_NOT_REACH_DIAGNOSTICS` 哨兵，测试确认公开 state/description 不含 payload。
- `HTTPLogRedactor` 新增 `qrcode_key`；测试确认轮询 URL 不保留 key。
- `Scripts/check-secrets.sh` 扫描疑似真实二维码 key、`SESSDATA`、`bili_jct` 和 refresh token 值，CI 在构建前执行。

## 3. 自动测试

新增 10 项 `BiliAuthTests`：

1. 生成请求、二维码主机、公开描述与内存 QR 图像。
2. `86101` 保持等待扫码，并验证轮询 key 脱敏。
3. 未知状态失败关闭且不泄漏 payload。
4. 网络失败映射为安全状态。
5. HTML 风控页在解码前拒绝。
6. Task 取消传播并清理状态。
7. 无活跃 challenge 时不发轮询请求。
8. 相似后缀主机不通过精确白名单。
9. 旧二维码响应不能覆盖新的 generation。
10. 较旧的并发轮询不能清除较新的等待状态。

完整 Package 当前为 64 项测试、14 个测试套件。

## 4. 人工探针边界

`BiliAuthProbe` 显示一个仅驻留内存的二维码窗口，每 2 秒轮询，180 秒本地超时。终端只允许以下信息：

- 安全状态名；
- 二维码 host；
- 未支持的业务状态 code；
- 安全错误分类。

它禁止输出 `qrcode_key`、QR URL、请求查询、响应 body、Cookie/token 值和账号身份。当前遇到第一个非 `86101` 状态便停止，确保未经证据确认的状态不会被猜测为成功。

`--generate-only` 模式只走生成 endpoint、精确主机校验和内存 QR 渲染，随后立即清除 session；它不显示二维码，也不轮询，适合验证生产代码路径没有发生基础漂移。

本地真实运行结果：

```text
state=requesting-qr-code
state=qr-generated qr-host=account.bilibili.com
```

输出中没有 key、URL 查询、响应 body、Cookie 或 token。

## 5. 下一 Gate

由开发者显式运行探针并扫码。每轮只确认一个新状态或字段结构，记录脱敏事实并以全假值 fixture 固定；确认扫码未确认、成功、过期、凭据来源、Cookie 白名单和登录态校验之前，不实现 Keychain 或请求授权。

## 6. 本地回归结果

- 环境：macOS 26.5.2（25F84）、Apple Silicon arm64、Xcode 26.6（17F113）。
- `Scripts/check-architecture.sh`：通过，新增 Auth 依赖边界已生效。
- `Scripts/check-secrets.sh`：通过，未发现疑似真实认证值。
- Package：64 项测试、14 个测试套件全部通过。
- App：macOS 15 deployment target 无签名 `build-for-testing` 通过。
- App composition：1 项单元测试通过，0 项失败。
- `BiliAuthProbe --generate-only`：通过正式 endpoint 获取并在内存渲染 QR，只输出安全状态与 `account.bilibili.com` 主机。
- Markdown 相对链接与 `git diff --check`：通过。

远程 macOS 15/26 CI 结果在提交推送后检查；本记录不把尚未运行的远程结果预写为事实。
