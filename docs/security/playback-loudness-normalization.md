# 播放响度均一化安全边界

## 数据与验证

- playurl `volume` 只作可选解码；六个必要数值必须完整、有限且在保守范围内，否则整组丢弃。
- `PlaybackLoudnessMetadata` 只保存策略所需的 measured integrated/LRA/true peak/threshold 与 target
  integrated/true peak。不得保存 `target_offset`、`multi_scene_args`、原始响应、Cookie、完整 URL/query、
  BVID/CID、标题或样本身份。
- metadata 属于当前 CID 的当前语义音轨响应。original、AI 与语言轨不能互相借用；无法唯一映射即 unity。

## 播放与实时线程

- macOS 26 且新 load 的设置快照开启时才可能安装 tap；macOS 15 不安装。tap 工厂失败、格式不匹配或
  callback 未触发都不能阻止播放。
- process callback 只读取固定内存/原子值并原位乘 Float32 PCM；不得分配、阻塞、记录日志、发起 Task、
  actor hop、加锁、访问网络或查找业务模型。AudioBufferList 必须按每个 buffer 的真实 byte size 限界。
- prepare 与 start-of-stream discontinuity 重置 ramp；item/generation 替换、retry、stop、failure 与返回
  页面必须移除 observer、取消选择任务并释放旧 tap，旧状态不得更新新 item。
- gain 不进入 `AVPlayer.volume`、用户偏好、系统音量、日志或设置。mute 与用户音量保持既有语义。

## 平台声明

无显式 HLS track 的 Processing Tap 不是 Apple 文档保证。macOS 26 的成功只能证明当前已验证环境可运行；
未 prepare/process 不能被当作“已检测全部失效”。设置文案必须持续声明实验性、仅 macOS 26、可能随系统
更新失效，以及下一次新播放生效。
