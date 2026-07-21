# M3 Keychain 与请求授权自动化验证（2026-07-21）

> 结论：M3 第 4 步的代码与自动化 Gate 已通过；真实 Data Protection Keychain 往返仍需签名 App 与最小 entitlement，因此本记录不关闭 M3。

## 1. 实现范围

- `WebCredential` 固定五项 Cookie，使用 schema v1 JSON envelope；解码后重新检查精确名称集合、`.bilibili.com`、`Path=/`、`Secure`、过期时间和值的大小/字符边界。
- 凭据类型的 description、debug description 与 Mirror 均不展示 Cookie 值。
- `KeychainWebCredentialStore` 使用 generic-password、固定且不含 UID 的 service/account；所有操作显式带 `kSecUseDataProtectionKeychain=true` 与 `kSecAttrSynchronizable=false`，新增/更新固定 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`。
- 保存先 add；只有 `errSecDuplicateItem` 才使用同一主键 update。读取、删除与 locked/unavailable/未知 OSStatus 均有安全错误映射。
- `BiliNetworking` 新增无 Bilibili 语义的 `HTTPRequestAuthorizing`，并提供 follow/reject 两种重定向策略；架构脚本禁止 Networking 导入 Auth、Security 或 UI/播放框架。
- `BiliCredentialRequestAuthorizer` 当前只允许 `GET https://api.bilibili.com/x/web-interface/nav`。它拒绝 HTTP、相似主机、CDN、loopback、错误 path/method、userinfo、fragment 与预置 Cookie。
- Web QR 的提交入口只在最新 generation 的 nav `isLogin=true` 后同步写入 store；只校验入口继续供脱敏探针使用，不落 Keychain。
- 恢复入口对缺失、损坏、过期和远端 `isLogin=false` 回退未登录并按规则清理；临时网络失败保留本地凭据并返回安全错误。

## 2. 自动测试

本轮新增 17 项测试：

1. envelope v1 往返与诊断脱敏。
2. 未知 schema version 拒绝。
3. 缺项或不安全 Cookie 集合拒绝。
4. Data Protection Keychain 查询、固定 service/account、非同步、WhenUnlockedThisDeviceOnly 与 add/update/read/delete 行为。
5. locked/unavailable Keychain 状态映射。
6. 精确 nav endpoint 添加 Cookie。
7. HTTP、相似主机、CDN、loopback、错误 path/method、userinfo、fragment 和跨主机重定向拒绝。
8. 调用方预置 Cookie 拒绝。
9. 无凭据拒绝。
10. 过期或损坏凭据清理。
11. 有效凭据恢复时只请求精确 nav。
12. 缺失或远端失效凭据回退并清理。
13. 临时 nav 失败不误删。
14. Web QR nav 成功后一次提交完整五项凭据。
15. Web QR nav `isLogin=false` 不提交。
16. 新二维码 generation 阻止旧 nav 结果写入 store。
17. Keychain save 失败不能返回持久登录成功。

现有清理测试同时覆盖 Keychain delete 失败必须上抛 store unavailable，不能伪装成已安全回退。完整 Package 为 87 项测试、16 个测试套件；全部通过。

## 3. 未签名环境边界

实现期间曾直接从未签名 SwiftPM 测试进程访问 Data Protection Keychain，store 返回 unavailable，未创建 item。该错误映射同时覆盖 `errSecMissingEntitlement` 与 `errSecNotAvailable`，因此这里不把具体原因写成已确认事实。这个进程不能提供真实持久化证据；Data Protection Keychain 仍须在具备正确签名/entitlement 的 App 上验证。

因此 CI 自动测试使用窄 `KeychainOperating` 后端检查传给 SecItem 的完整查询、数据和状态分支，而不是降级到 legacy Keychain。后续签名 smoke 必须：

1. 使用独立测试 service/account；
2. 真实执行 add、duplicate→update、read、delete；
3. 检查 Data Protection、WhenUnlockedThisDeviceOnly 与非同步属性；
4. 在 teardown 删除测试 item；
5. 不输出 envelope 或 Cookie 值。

## 4. 本地回归

- 环境：macOS 26.5.2（25F84）、Apple Silicon arm64、Xcode 26.6（17F113）。
- Package：87 项测试、16 个测试套件全部通过。
- 架构依赖检查：通过，新增 Networking 纯净边界已生效。
- 秘密模式扫描：通过。
- App：macOS 15 deployment target 无签名 `build-for-testing` 通过。
- App composition：1 项单元测试通过，0 项失败。
- Markdown 相对链接与 `git diff --check`：通过。

远程 macOS 15/26 CI 结果在提交推送后检查；本记录不预写尚未运行的结果。
