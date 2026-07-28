# 播放测试材料

这些 fixture 均由合成源生成，不包含下载的媒体内容：

- `video-avc.mp4`：蓝色 128×72 H.264/AVC 视频。
- `video-avc-256x144.mp4.base64`：绿色 256×144 H.264/AVC 视频的 Base64 文本，
  测试时只在内存解码，用于不同分辨率 HLS variant 验证。
- `video-avc-128x72-4s-global-sidx.mp4.base64` 与
  `video-avc-256x144-4s-global-sidx.mp4.base64`：四秒、四个一秒 fragment 的蓝色／
  绿色 H.264 视频，单个 global SIDX 覆盖全部 fragment。
- `audio-aac-4s-global-sidx.mp4.base64`：与上述视频配套的四秒静音 AAC；
  三者用于同一 `AVPlayerItem` 的运行时 HLS 降档验证。
- `audio-aac.mp4`：440 Hz AAC 音频。
- `sidx-v0-two-references.hex`：手工编写、包含两个直接媒体引用的 SIDX v0 box。

这些 MP4 使用 FFmpeg 8.1.2 生成；仓库中标记为 `.base64` 的文件在生成后使用同一
`base64 -i input.mp4 -o output.mp4.base64` 方式转为文本：

```sh
ffmpeg -f lavfi -i 'color=c=blue:s=128x72:r=24:d=2' \
  -c:v libx264 -pix_fmt yuv420p -profile:v main \
  -g 24 -keyint_min 24 -sc_threshold 0 -an \
  -movflags +dash+frag_keyframe+empty_moov+default_base_moof \
  -f mp4 video-avc.mp4

ffmpeg -f lavfi -i 'color=c=green:s=256x144:r=24:d=2' \
  -c:v libx264 -pix_fmt yuv420p -profile:v main \
  -g 24 -keyint_min 24 -sc_threshold 0 -an \
  -movflags +dash+frag_keyframe+empty_moov+default_base_moof \
  -f mp4 video-avc-256x144.mp4

base64 -i video-avc-256x144.mp4 \
  -o video-avc-256x144.mp4.base64

ffmpeg -f lavfi -i 'color=c=blue:s=128x72:r=24:d=4' \
  -c:v libx264 -pix_fmt yuv420p -profile:v main \
  -g 24 -keyint_min 24 -sc_threshold 0 -an \
  -movflags +dash+global_sidx+frag_keyframe+empty_moov+default_base_moof \
  -f mp4 video-avc-128x72-4s-global-sidx.mp4

ffmpeg -f lavfi -i 'color=c=green:s=256x144:r=24:d=4' \
  -c:v libx264 -pix_fmt yuv420p -profile:v main \
  -g 24 -keyint_min 24 -sc_threshold 0 -an \
  -movflags +dash+global_sidx+frag_keyframe+empty_moov+default_base_moof \
  -f mp4 video-avc-256x144-4s-global-sidx.mp4

ffmpeg -f lavfi -i 'anullsrc=channel_layout=stereo:sample_rate=48000:d=4' \
  -c:a aac -b:a 32k -vn \
  -movflags +dash+global_sidx+frag_keyframe+empty_moov+default_base_moof \
  -f mp4 audio-aac-4s-global-sidx.mp4

ffmpeg -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=2' \
  -c:a aac -b:a 96k -vn \
  -movflags +dash+frag_keyframe+empty_moov+default_base_moof \
  -f mp4 audio-aac.mp4
```
