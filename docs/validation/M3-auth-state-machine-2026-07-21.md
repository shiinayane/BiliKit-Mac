# M3 Web QR 基础状态机验证（2026-07-21）

> 结论：M3 第 2 步基础状态机与第 3 步成功/过期协议 Gate 已通过；Cookie 仅完成短生命周期内存校验，Keychain、通用请求授权和登录 UI 尚未实现，M3 Gate 尚未关闭。

## 1. 实现范围

- 新增 `BiliAuth` library target 和由它实际驱动的 `BiliAuthProbe` executable target。
- 生产认证 transport 使用独立 `URLSessionConfiguration.ephemeral`，关闭自动 Cookie、Cookie storage 和 URL cache，设置 15 秒请求/30 秒资源超时，并拒绝 HTTP 重定向。
- `WebQRLoginSession` actor 实现二维码生成、一次轮询、取消、网络/HTTP/HTML/解码失败和未知状态处理。
- 当前接受 2026-07-21 现场确认的 `86101` 未扫码、`86090` 已扫码待确认、`0` 待凭据校验和 `86038` 过期状态；其他业务状态返回仅含 code 与安全结构信息的 `unsupported-status`，不输出服务端 message、URL、refresh token 或 Cookie 值。
- 生成结果只接受 HTTPS 和 `account.bilibili.com` 精确主机；相似后缀主机会被拒绝。
- 原始 QR URL 封装在不可直接读取的 `WebQRCode` 中，由 Core Image 在内存生成图像；探针不落盘，也不打印二维码内容。
- generation/poll ID 阻止旧请求覆盖更新意图；Swift Task 取消会传播并清回 signed-out。

## 2. Fixture 与秘密边界

- 生成、`86101`、`86090`、`0`、`86038` 和未知状态均使用手写 JSON fixture；二维码 key 明确使用 `FIXTURE_` 哨兵。
- 成功 fixture 只含全假值；Cookie header 在测试代码中现场构造，真实 Cookie 不进入仓库。
- 未知状态 fixture 使用 `TOP_SECRET_SHOULD_NOT_REACH_DIAGNOSTICS` 哨兵，测试确认公开 state/description 不含 payload。
- `HTTPLogRedactor` 新增 `qrcode_key`；测试确认轮询 URL 不保留 key。
- `Scripts/check-secrets.sh` 扫描疑似真实二维码 key、`SESSDATA`、`bili_jct` 和 refresh token 值，CI 在构建前执行。

## 3. 自动测试

新增 16 项 `BiliAuthTests`：

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
11. 安全观察只暴露字段、URL 查询和 Cookie 的名称/属性，不暴露值。
12. `86090` 进入等待手机确认状态，并继续使用同一 generation。
13. `code=0` 只进入待凭据校验，公开状态只含安全结构。
14. Set-Cookie 精确白名单请求 nav，未知 Cookie 不进入授权头。
15. `86038` 进入过期状态并清除活跃 challenge。
16. 新二维码生成后，较旧的在途 nav 校验不能返回可提交结果。

完整 Package 当前为 70 项测试、14 个测试套件。

## 4. 人工探针边界

`BiliAuthProbe` 显示一个仅驻留内存的二维码窗口，每 2 秒轮询，180 秒本地超时。终端只允许以下信息：

- 安全状态名；
- 二维码 host；
- 未支持的业务状态 code；
- data 字段名、URL scheme/host/查询键名、响应 header 名；
- Cookie 名称、属性名、domain/path 与布尔元数据；
- refresh token 是否存在和 nav `isLogin` 布尔结果；
- 安全错误分类。

它禁止输出 `qrcode_key`、QR URL、请求查询、响应 body、Cookie/token 值和账号身份。交互模式只处理已经现场确认的 `86101`、`86090` 和 `0`，其中 `0` 必须完成 nav 校验后立即清理内存；`--observe-expiry` 只接受 `86101` 与 `86038`。其他状态一律失败关闭。

`--generate-only` 模式只走生成 endpoint、精确主机校验和内存 QR 渲染，随后立即清除 session；它不显示二维码，也不轮询，适合验证生产代码路径没有发生基础漂移。

本地真实运行结果：

```text
state=requesting-qr-code
state=qr-generated qr-host=account.bilibili.com
```

输出中没有 key、URL 查询、响应 body、Cookie 或 token。

### 已扫码未确认观察

第二轮由开发者扫码但不确认，在写入正式映射前得到：

```text
state=failed-unsupported-status-86090
data-fields=code,message,refresh_token,timestamp,url
url-scheme=none
url-host=none
url-query-names=none
refresh-token-present=false
cookie-names=none
cookie-attribute-names=none
```

据此将 `86090` 固定为 `awaitingConfirmation`，继续轮询但不读取或保存认证材料。

### 成功与登录态校验观察

成功状态为 `code=0`。安全观察确认：

- data 字段：`code`、`message`、`refresh_token`、`timestamp`、`url`；
- URL：HTTPS，host 为 `passport.biligame.com`；
- URL 查询键：`DedeUserID`、`DedeUserID__ckMd5`、`Expires`、`SESSDATA`、`bili_jct`、`first_domain`、`gourl`；
- Set-Cookie 名称：`DedeUserID`、`DedeUserID__ckMd5`、`SESSDATA`、`bili_jct`、`sid`；
- 五项 Cookie 均为 `.bilibili.com`、`Path=/`、`Secure` 且有 expiry；`SESSDATA` 另有 `HttpOnly`；
- refresh token 存在，但值没有输出、保存或使用。

探针只从 Set-Cookie 提取上述五项到短生命周期内存，忽略 JSON URL 与未知 Cookie 的值；请求 `https://api.bilibili.com/x/web-interface/nav` 得到 `isLogin=true`，随后清空。

### 过期观察

不显示二维码并持续轮询，在写入正式映射前于第三分钟内得到：

```text
state=failed-unsupported-status-86038
data-fields=code,message,refresh_token,timestamp,url
url-scheme=none
url-host=none
url-query-names=none
refresh-token-present=false
cookie-names=none
cookie-attribute-names=none
```

据此将 `86038` 固定为 `expired`。观察只证明当次服务端行为，不把约 3 分钟写成稳定有效期承诺。

## 5. 下一阶段

成功/过期协议 Gate 已完成。下一阶段实现 Data Protection Keychain store 与 endpoint 级请求授权器：凭据仍须先通过 nav 校验，随后才能原子提交 Keychain；损坏、失效或缺失凭据必须回退游客模式。完成持久化、授权边界和登出测试之前，不创建登录 Feature。

## 6. 本地回归结果

- 环境：macOS 26.5.2（25F84）、Apple Silicon arm64、Xcode 26.6（17F113）。
- `Scripts/check-architecture.sh`：通过，新增 Auth 依赖边界已生效。
- `Scripts/check-secrets.sh`：通过，未发现疑似真实认证值。
- Package：70 项测试、14 个测试套件全部通过。
- App：macOS 15 deployment target 无签名 `build-for-testing` 通过。
- App composition：1 项单元测试通过，0 项失败。
- `BiliAuthProbe --generate-only`：通过正式 endpoint 获取并在内存渲染 QR，只输出安全状态与 `account.bilibili.com` 主机。
- Markdown 相对链接与 `git diff --check`：通过。

远程 macOS 15/26 CI 结果在提交推送后检查；本记录不把尚未运行的远程结果预写为事实。
