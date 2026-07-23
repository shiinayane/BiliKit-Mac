# M4 scheduler 去重保留边界修复契约

> Revision：D1。状态：用户已于 2026-07-23 确认三项授权，允许按本契约实施。

## 通俗摘要

弹幕 renderer 本身的 30 分钟内存稳定，但完整生产链路还有一个更早的 scheduler：它会永久记住本次播放已经显示过的每个弹幕 ID，普通向前播放不会随旧分段淘汰这些记录。长视频因此可能缓慢增长内存。修复只让去重记录与有限分段窗口一起淘汰，同时保留 seek、重复 ID 和旧 generation 隔离语义；不改 renderer、网络协议、UI 或业务范围。

## 决定与范围

本轮只决定：如何让正常连续播放中的去重状态具有与分段 cache 对齐的明确上界，同时不重复喷射仍在有效窗口内的弹幕。

允许修改：

- `DanmakuScheduler` 的去重状态及其最窄内部诊断；
- scheduler/session 的确定性测试；
- 既有 `BiliDanmakuProbe` 的单一路径，使受控负载经过 session/scheduler；
- 对应验证记录与路线图。

不允许修改 renderer 路线、API/protobuf、真实 endpoint、App UI、Package/target、持久化或通用 benchmark framework。

## 必须保持

- 同一 identity、generation 和保留窗口内，相同事件 ID 最多投递一次；
- 向后 seek、generation 变化、换视频、disable/reset 的既有清空语义不退化；
- segment cache 仍最多三段，请求并发、预取与错误边界不改变；
- 去重状态的上界必须由保留分段数和单段既有限额推导，不能靠任意时间或经验阈值。

## 最低证据与完成条件

1. 确定性测试跨越多于三段，证明旧分段去重状态会淘汰、相邻分段重复 ID 不会重复显示，seek/generation/reset 后行为保持；
2. 测试能够直接断言去重状态上界，而不以进程 RSS 猜测集合大小；
3. 一个受控入口经过 repository/session/scheduler/controller/renderer，跨越多于三段后 RSS 不持续增长，stop 后 session、controller active count、layer 与 root attachment 清理；
4. Package/App/static Gate 与独立红区复审通过；PR 的 macOS 15/26 CI 通过后才关闭 M4。

## 停止与复杂度预算

- 若必须重写 scheduler、改变分段协议或建立通用 benchmark 框架，立即停止并重新授权；
- 最多修改一个生产类型、对应测试、一个既有 probe 路径和文档；
- 不增加第二种去重策略、配置开关或没有调用方的公共 API；
- harness 不得比去重修复本身更复杂；先用虚拟时间跨段，只有其不能回答 RSS 时才延长 wall-clock。

## 授权问题

1. 是否同意把去重状态改为随有限分段窗口淘汰，并保持相邻重复、seek 与 generation 语义？
2. 是否授权只修改上述 scheduler、测试、既有 probe 路径和文档？
3. 是否同意 M4 保持打开，直到窄修复、独立复审和 macOS 15/26 CI 全部通过？
