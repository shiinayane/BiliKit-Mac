# Playback fixtures

These fixtures are generated from synthetic sources and contain no downloaded
media:

- `video-avc.mp4`: blue 128×72 H.264/AVC video.
- `audio-aac.mp4`: 440 Hz AAC audio.
- `sidx-v0-two-references.hex`: hand-authored version 0 SIDX box with two direct
  media references.

The MP4 files were generated with FFmpeg 8.1.2:

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
