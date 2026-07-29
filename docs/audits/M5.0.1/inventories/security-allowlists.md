# 安全白名单清单

状态：Gate 1 枚举中；由主 Agent 单写。

需要逐项补齐：

- API host、path、method、query 与是否允许 Cookie；
- QR 生成／轮询 host、二维码显示 URL host 和 redirect policy；
- 字幕目录、字幕正文与弹幕 endpoint；
- DASH 视频／音频／backup URL 的 host 与 path；
- Range session、Content-Type、Content-Range 和 redirect；
- loopback 的 scheme、host、port、route 与响应 header；
- 日志 redaction 字段、错误描述和 probe 输出边界。

任何结论不得把精确 allowlist 直接改成后缀或通配匹配。

## 当前代码枚举

### API 与认证

- API base：`https://api.bilibili.com`；
- 游客 endpoints：`/x/web-interface/popular`、`/x/web-interface/view`、
  `/x/player/pagelist`、`/x/player/playurl`、`/x/web-interface/wbi/search/type`、
  `/x/web-interface/nav`（WBI key）、`/x/v2/dm/web/seg.so`；
- 可携带 Cookie 的 authorizer allowlist：
  `/x/web-interface/nav`、`/x/web-interface/history/cursor`、
  `/x/player/wbi/v2`，均限定 HTTPS、`api.bilibili.com`、GET、端口 443／默认端口、
  无 user/password/fragment，并校验精确 query 集合；
- QR base：`https://passport.bilibili.com`，生成／轮询 paths 为
  `/x/passport-login/web/qrcode/generate` 与 `/x/passport-login/web/qrcode/poll`；
- QR 展示 payload 当前只接受 `https://account.bilibili.com`；
- Auth、授权 API、字幕正文和 Range 的专用 URLSession 均关闭 Cookie storage/cache
  并拒绝 redirect；常规游客 `BiliAPIClient` transport 的 redirect 策略仍需独立确认。

### 字幕、媒体与图片

- 字幕正文：只接受 `https://aisubtitle.hdslb.com:443/bfs/...`；
- 媒体：先经过公共 HTTPS／非本地地址检查，再允许 `bilivideo.com`、
  `bilivideo.cn`、`szbdyd.com` 的根域／子域，以及
  `upos-*.akamaized.net`；`.example.invalid` 只供 fixture；
- 视频卡图片当前只允许 `hdslb.com` 根域／子域；
- media 与 subtitle policy 的 host 范围都属于当前外部事实候选，不能因测试覆盖就视为
  长期完整。

### Loopback

- server 只应绑定 `127.0.0.1`；
- 请求必须携带唯一 Host，且精确等于当前 listener 的 `127.0.0.1:<port>`；缺失、重复、
  格式异常或不匹配均返回 400；
- route 带随机 session token，并验证相对 route 形状；
- 只允许 GET/HEAD；当前独立进程矩阵已覆盖实际监听、token/path、断连清理与 stop 后
  端口关闭，Range response 的完整 RFC 语义仍由媒体线继续裁决。
