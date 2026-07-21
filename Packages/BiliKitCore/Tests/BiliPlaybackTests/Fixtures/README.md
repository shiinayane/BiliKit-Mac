# 播放测试材料

这些 fixture 均由合成源生成，不包含下载的媒体内容：

- `video-avc.mp4`：蓝色 128×72 H.264/AVC 视频。
- `audio-aac.mp4`：440 Hz AAC 音频。
- `sidx-v0-two-references.hex`：手工编写、包含两个直接媒体引用的 SIDX v0 box。

两个 MP4 文件使用 FFmpeg 8.1.2 生成：

```sh
ffmpeg -f lavfi -i 'color=c=blue:s=128x72:r=24:d=2' \
  -c:v libx264 -pix_fmt yuv420p -profile:v main \
  -g 24 -keyint_min 24 -sc_threshold 0 -an \
  -movflags +dash+frag_keyframe+empty_moov+default_base_moof \
  -f mp4 video-avc.mp4

ffmpeg -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=2' \
  -c:a aac -b:a 96k -vn \
  -movflags +dash+frag_keyframe+empty_moov+default_base_moof \
  -f mp4 audio-aac.mp4
```
