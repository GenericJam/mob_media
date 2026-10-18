# MobMedia

Media helpers for [Mob](https://hexdocs.pm/mob) apps, through the platform's
own decoders: what's in a media file, its audio as PCM for speech-to-text, and
a video frame as a JPEG.

```elixir
{:ok, %{duration_ms: 12_480, has_video: true, width: 1080, height: 1920}} =
  MobMedia.info(path)

{:ok, pcm} = MobMedia.audio_pcm(path)        # 16 kHz mono s16le
{:ok, text} = MobWhisper.transcribe(pcm)

{:ok, jpeg} = MobMedia.frame(path, 4_000, max_px: 1024)
```

| | Android | iOS |
|--|--|--|
| `info/2` | `MediaExtractor` + `MediaMetadataRetriever` | `AVURLAsset` |
| `audio_pcm/2` | `MediaExtractor` + `MediaCodec`, downmix/resample in the bridge (`MobMedia.PCM`'s algorithm) | `AVAssetReader` with LinearPCM output settings |
| `frame/3` | `MediaMetadataRetriever` (`OPTION_CLOSEST`) + `Bitmap.compress` | `AVAssetImageGenerator` (zero tolerance) + ImageIO |

Anything the platform's decoders handle works; verified on both platforms:
m4a/AAC, mp3, wav, ogg/opus and mp4/H.264. No ffmpeg and no runtime permission: `path` is a local
file the app can already read (from `Mob.Files.pick/2`, mob_photos,
mob_camera or `Mob.Audio`), not a `content://` URI.

## API

* `MobMedia.info(path, opts)` →
  `{:ok, %{duration_ms, width, height, has_audio, has_video, mime}}`.
  `width`/`height` are the size the video is shown at (rotation applied);
  `nil` without video. Unknown fields are `nil`.
* `MobMedia.audio_pcm(path, opts)` → `{:ok, pcm}`: signed 16-bit
  little-endian interleaved PCM, the format `MobWhisper.transcribe/2` takes.
  Options `rate:` (default `16_000`), `channels:` (`1` default, or `2`),
  `to:` (write the PCM to that file and return `{:ok, to}`), `timeout:`.
  The first audio track of an audio file or a video. `{:error, :no_audio}`
  when there's none.
* `MobMedia.frame(path, at_ms, opts)` → `{:ok, jpeg}`: the exact frame at
  that time, upright, scaled down to `max_px:` (default `1280`, `nil` for full
  size, never scaled up), `quality:` 1..100 (default `85`). Past the end gives
  the last frame. `{:error, :no_video}` without video.

Errors: `:not_found`, `:unsupported`, `:no_audio`, `:no_video`,
`:decode_failed`, `:io_error`, `:timeout`, `:unavailable` (the NIF isn't in
this build), and on Android `{:jni, reason}`.

### Sync, off the schedulers

Every function blocks **the calling process** until its answer is ready. The
NIF only queues the job and returns; the work runs on a native thread (a
two-thread Kotlin pool on Android, a GCD queue limited to two jobs on iOS)
and the result comes back as a `{:mob_media, ref, result}` message to a
short-lived worker process that each call starts. No BEAM scheduler, normal
or dirty, is held while a file decodes.

Decoding takes time: on a Moto G 2021 (a debug build, on a busy phone) a
2-minute m4a decoded to 16 kHz mono in 12–23 s and a 2-minute 1080p mp4's
audio track in 15–35 s; an exact video frame takes about a second when the
video has a keyframe every second (as phone recordings do). The iOS
simulator does a 6 s clip in 30 ms. So call it from a task in a screen, not
from `handle_event` directly:

```elixir
screen = self()
Task.start(fn -> send(screen, {:pcm_ready, MobMedia.audio_pcm(path)}) end)
```

A call that times out returns `{:error, :timeout}` at once; the native job
finishes in the background and its output is deleted. A caller that dies is
handled the same way.

### Memory

The platform side streams the PCM into a file as it decodes; nothing holds
the whole decode in native memory. Without `to:` that file is temporary and
read into the returned binary (16 kHz mono is 1.9 MB a minute, 115 MB an
hour). For long recordings pass `to:` and read it a window at a time (whisper
works in 30 s windows, 960 000 bytes at 16 kHz mono):

```elixir
{:ok, pcm_path} = MobMedia.audio_pcm(video, to: Path.join(dir, "audio.pcm"))
{:ok, fd} = :file.open(pcm_path, [:read, :binary, :raw])
{:ok, window} = :file.pread(fd, 0, 960_000)
```

### Accuracy

The PCM covers the decoded track. Its length matches `info`'s duration within
a few tens of milliseconds, except that AAC files report the container
duration, which includes the encoder's priming and padding the decoder
trims (a 5.02 s speech m4a: 5155 ms on Android, PCM 5024 ms). iOS's mp3
decoder keeps about 26 ms of leading decoder delay. On Android the
conversion is exactly `MobMedia.PCM.convert/5` (box-filter downsampling,
linear upsampling, channel averaging); iOS uses Core Audio's converter.

## Installation

Not on Hex yet; pin the GitHub commit:

```elixir
# mix.exs
{:mob_media, github: "GenericJam/mob_media", ref: "<commit>"}
```

```elixir
# mob.exs
config :mob, :plugins, [..., :mob_media]

config :mob, :trusted_plugins, %{
  # ...
  mob_media: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg="
}
```

That's the shared first-party mob key. A GitHub checkout has no signature
(`priv/mob_plugin.sig` is made by the release workflow), so until the Hex
release sign it once in the dep: `cd deps/mob_media && mix mob.plugin.sign`
with the first-party key in `~/.mob/keys/mob_media.priv`, or acknowledge it
as unsigned with `config :mob, :acknowledge_unsafe_plugins, [:mob_media]`.
Then `mix mob.deploy --native`.

## Testing without a device

```elixir
# config/test.exs
config :mob_media, engine: MobMedia.Engine.Fake
```

`MobMedia.Engine.Fake` decodes WAV files for real (so a test can feed a
recording through to transcription) and answers scripted results for any
other path:

```elixir
MobMedia.Engine.Fake.script(path,
  info: %{duration_ms: 6_000, has_audio: true, has_video: true, width: 720, height: 1280},
  audio: {pcm, 16_000, 1},
  frame: {jpeg, 720, 1280}
)
```

## On a device

`MobMedia.DemoScreen` (route `/mob_media/demo`) picks a file and shows its
info, its decoded audio length and its frame at one second. `MobMedia.SelfTest`
runs under `mix mob.selftest`: a WAV it writes is probed and decoded to 16 kHz
mono through the NIF.

Verified on a Moto G Power 2021 (Android 11) and an iPhone 17 simulator
(iOS 27): m4a, mp3, wav, ogg/opus and mp4 (landscape, rotated portrait, no
audio). Not yet run on a physical iPhone.
