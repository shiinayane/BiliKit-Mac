# 观看进度 Web heartbeat 生产收口（2026-08-25）

状态：协议证据、两次用户执行的真实可见性验证与生产 deterministic contract 已收口

## 证据边界

- 2026-08-24 的 spike 由当日 Bilibili 官方播放器 bundle、独立协议整理与一次用户亲自操作的有界
  真实账号验证三层交叉支持。真实验证只比较官方网页与 BiliKit 观看历史中的可见行为，没有抓取
  流量、读取凭据或记录内容 identity。
- 当次可见行为确认：进入 playing 立即产生历史，暂停立即更新，正常播放每 15 秒更新，约 18 秒退出
  记录约 18 秒。该证据只代表当日普通投稿样本，不是上游稳定 API 承诺。
- Codex 的实现与自动验证没有调用真实 heartbeat、读取真实凭据或产生观看历史。实现完成后，用户于
  2026-08-25 主动操作当前 worktree 的 Debug App，实际观察到开始播放立即上报、暂停立即上报、退出
  立即上报、播放中每 15 秒上报，以及 Web 与 BiliKit 两端历史记录准确一致。
- 2026-08-25 的结论来自用户可见行为，不是 Codex 抓包、凭据检查或响应检查；没有记录账号、内容
  identity、标题、具体位置、Referer、请求 URL/字段或响应正文，也不构成上游稳定 API 承诺。

## 生产边界

- 唯一写 endpoint 为 `POST https://api.bilibili.com:443/x/click-interface/web/heartbeat`；WBI nav 匿名，
  最终请求才由独立 Auth 写授权器注入最小凭据。
- 游客/unresolved 不创建报告。登录会话开始、15 秒周期、暂停、恢复、自然结束和 unload 分别固定
  `play_type=1/0/2/3/4`；自然结束使用 `played_time=-1`，其他退出使用当前实际位置。
- 每窗口最多一个提交调用和 8 个待处理事件；周期只保留最新，边界淘汰周期，饱和时中间暂停/恢复
  合并为最新状态，最终 ended 始终入队。进程 writer 在所有窗口间保持单并发。
- HTTP 403/412、认证、签名、网络、解析和业务失败关闭匹配报告 session，不走共享认证重校验，
  不改变播放器。登出/换号仍推进全局账户代次并取消所有 writer/transport owner。
- 不持久化观看位置或请求，不离线排队，不恢复崩溃前写入；测试使用虚构值和 fake transport。

## 自动验证范围

- Application：开始/周期/暂停/恢复/结束、18 秒退出、回退 seek、buffering、睡眠/唤醒、游客预检、
  失败与播放器解耦、慢 started 前 ended、快速边界饱和、进程单并发与认证代次取消。
- API：精确 WBI query/form/Referer/header、自然结束 sentinel、缺少 authorizer 时零 transport、
  HTTP 403/412 与认证业务码映射。
- Auth：精确 origin/path/method/header/query/body allowlist、镜像值交叉核对、拒绝预置秘密/扩展字段，
  只注入虚构 `SESSDATA` 与虚构 CSRF。

当前 Debug App 的开始、暂停、退出、15 秒周期和两端历史可见性已有用户观察；恢复、自然结束、真人
VoiceOver/FKA、真实睡眠、多窗口同时退出、网络断开恢复、Release/Developer ID 成品与上游长期兼容性
仍没有本轮实际观察，也不由 deterministic 测试替代。
