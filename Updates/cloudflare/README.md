# BiliKit HTTPS 更新源

独立的 Cloudflare Workers Static Assets 目录。2026-09-05 已获用户授权并部署：
Worker `bilikit-updates`，URL `https://updates.shiinayane.com/appcast.xml`。
build 2 和 build 3 测试安装包已作为独立 GitHub prerelease 公开；线上双版本 feed/DMG 原始字节、哈希及公钥验签通过，
HTTPS、缓存头和 404 行为通过。用户已确认 build 2→3 升级成功、版本正确且登录状态保留；失败矩阵仍待验证。

只原样分发签名 feed，不包含 Worker 请求处理代码、DMG、私钥、用户凭据或 B 站代理。
`workers_dev` 和 preview URLs 关闭，未知路径返回 404，不使用 SPA fallback。

## 本地准备

需要 Node.js 22+、npm、Python 3，以及发布 Mac 的 Xcode/Sparkle 2.9.6 工具。
Wrangler 精确固定为 4.129.0，使用锁文件安装：

```sh
cd Updates/cloudflare
npm ci
npm test
```

1. 发布者在发布机运行官方 `generate_keys`，只让它在 login Keychain 生成/保存密钥。
   完成加密备份和隔离恢复；不要把私钥粘贴到终端参数、聊天、仓库、CI 或 Cloudflare。
2. 将工具打印的**公钥**填入本目录 `release.json` 的 `publicEDKey` 以及仓库
   `Configuration/BiliKit-Info.plist` 的 `SUPublicEDKey`。确认最终域名后，再将后者
   `BiliKitUpdaterEnabled` 改为 true。域名变更同时调整这两份配置、Wrangler route 与 `feed.py` 的 feed 契约。
3. 在新 commit/build 上重新 Archive、Developer ID export、App/DMG 签名、公证和 staple。
   不修改冻结的 1.0.0 (1) 候选。两个安装测试版本都必须带更新器；首次可用版本为 build 2，
   下一测试版本至少为 build 3。每次更新同步工程 build 契约。
4. 把一个新版本的最终完整 DMG 放入独立 release staging 目录。不要混放其他 tag 的归档。
   用固定包中的官方工具生成并签名 appcast，例如（变量均为本机路径或公开 tag）：

```sh
"$SPARKLE_BIN/generate_appcast" \
  --maximum-deltas 0 \
  --download-url-prefix "https://github.com/shiinayane/BiliKit-Mac/releases/download/$RELEASE_TAG/" \
  --embed-release-notes \
  "$RELEASE_STAGING"
```

`SPARKLE_BIN` 是 Xcode SwiftPM artifact 中 `artifacts/sparkle/Sparkle/bin`。
工具通过 Keychain 签名；`SURequireSignedFeed=true` 使官方工具同时签名 feed。
第一次只发布完整包、不生成 delta，不使用远程 release notes。如需说明，使用同名内嵌 HTML
片段，不包含远程资源。已有多版本 feed 的维护必须保留每个旧 asset URL，不能统一改到新 tag。

5. 公钥与 feed 在 App 中一致后，做**纯本地**暂存和验签：

```sh
python3 feed.py stage --feed "$RELEASE_STAGING/appcast.xml" \
  --app "$EXPORTED_APP" --archives "$RELEASE_STAGING"
npm run dry-run
```

`stage` 验证 App 的签名/Gatekeeper/staple、公开配置、feed 签名和每个本地 DMG 的长度与
Ed25519 签名，仅原样原子复制 appcast。Node 验签仅消费公钥；不调用会读取 Keychain 私钥的
`sign_update --verify`。它不替代 Archive manifest 对 App、DMG 内容、Team、架构与 hash 的交叉复核。
`validate`/`deploy` 再次检查 feed 签名与 public 文件白名单；它们不保留或上传 DMG。

## 后续实际部署

正式发布先完成安装失败矩阵。测试发布亦须确认固定 GitHub Release 资产已获准公开，且匿名下载可达、hash/字节数
与 appcast 一致。草稿资产不是正式下载源。确认 Cloudflare 账户、域名所有权和费用后，由发布者
使用 `wrangler login`；多账户时在本机选择/设置正确 account ID。不要提供 token 给聊天或仓库。

```sh
npm run deploy
```

这是唯一的一键外部部署步骤；会上传 `public` 并通过 Custom Domain route 创建/更新
`updates.shiinayane.com` 的路由与 DNS。不可在未批准时运行。本次测试发布已获得授权，完成登录、部署和 Custom Domain 创建；
后续发布按当次授权执行。不要覆盖旧安装资产。

部署后匿名检查 HTTPS、`Content-Type`、缓存头、404 行为与 feed 原始字节/hash，并用公钥重验。
appcast 浏览器缓存上限 300 秒，`no-transform` 防止内容转写；不要给 XML 开启修改响应正文的规则。
Cloudflare 静态资产请求当前免费且不计动态 Worker 请求，单文件上限 25 MiB；本流程主动把 feed
限制为 1 MiB，安装包继续在 GitHub。账户计划、域名费用和未来价格需要部署当日重新核对。

停用时先移除更新项并重新签名部署（保留 HTTPS feed 可用）；不要覆盖旧资产或降低 build。
需要彻底删除 Worker/域名时单独授权，已安装客户端将得到更新错误。失去 EdDSA 私钥时，
由于关闭了签名失败超时降级，可能需要从可信发布页手动安装新签名公证版本恢复。

官方资料：
[Static Assets](https://developers.cloudflare.com/workers/static-assets/)、
[配置](https://developers.cloudflare.com/workers/wrangler/configuration/)、
[响应头](https://developers.cloudflare.com/workers/static-assets/headers/)、
[费用](https://developers.cloudflare.com/workers/static-assets/billing-and-limitations/)、
[上限](https://developers.cloudflare.com/workers/platform/limits/)、
[Sparkle 发布](https://sparkle-project.org/documentation/)。
