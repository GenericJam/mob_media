# Changelog

All notable changes to **mob_media** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

## [0.1.0] - 2026-10-18

### Added
- `MobMedia.info/2`: duration, shown video size (rotation applied), which
  tracks a file has, and its MIME type. Android `MediaExtractor` +
  `MediaMetadataRetriever`, iOS `AVURLAsset`.
- `MobMedia.audio_pcm/2`: the first audio track of an audio file or a video,
  decoded to signed 16-bit little-endian PCM at `rate:` (default 16 kHz) and
  `channels:` (default mono), the format `MobWhisper.transcribe/2` takes.
  Android `MediaExtractor` + `MediaCodec` with the conversion in
  `MobMedia.PCM`; iOS `AVAssetReader` LinearPCM output settings. The native
  side streams to a file; `to:` keeps the PCM in a file for long recordings.
- `MobMedia.frame/3`: the exact video frame at a time as a JPEG, upright,
  scaled to `max_px:` at `quality:`. Android `MediaMetadataRetriever`, iOS
  `AVAssetImageGenerator`.
- Every call blocks only its caller; decoding runs on native threads, never a
  BEAM scheduler. `timeout:` on every call.
- `MobMedia.Engine.Fake` for host tests (real WAV decoding, scripted answers),
  `MobMedia.SelfTest` for `mix mob.selftest`, `MobMedia.DemoScreen` at
  `/mob_media/demo`.
