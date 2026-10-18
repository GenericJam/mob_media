# Native writes files; calls are synchronous for the caller only

- Date: 2026-10-18
- Status: accepted

## Context

mob_media turns media files into PCM (for whisper) and JPEG frames on
Android and iOS. Three questions shaped it.

1. **Where the decoding runs.** A Mob app's BEAM has one normal, one dirty
   CPU and one dirty IO scheduler. A dirty NIF that decodes a long video holds
   one of the two dirty schedulers for tens of seconds, starving everything
   else that needs one (file IO from other code, crypto, other plugins).
2. **How the result crosses the boundary.** A minute of 16 kHz mono PCM is
   1.9 MB; an hour of a video's audio is 115 MB. Handing bytes over JNI or an
   `enif_send` means the native side buffers the whole decode first, then
   copies it (Kotlin `ByteArray` → JNI → Erlang binary): two or three copies
   of the largest thing the plugin produces.
3. **What callers want.** bezalel_mob transcribes an attached recording or a
   video's audio track, and picks stills; `{:ok, pcm} = audio_pcm(path)` is
   the shape it asked for, and `MobWhisper.transcribe/2` is synchronous too.
   mob_video's socket-and-`handle_info` style suits screens but not a
   pipeline step.

## Decision

* The NIF only queues the job and returns. The work runs on native threads
  (a two-thread Kotlin pool on Android; an `NSOperationQueue` running two at a
  time on iOS) and replies with exactly one `{:mob_media, ref, result}` message.
* The native side **always writes its output to a file** whose path Elixir
  chose, streaming as it decodes, and sends only a small result (bytes
  written, frame size). Elixir reads the file into a binary, or renames it
  onto the caller's `to:` path, and deletes temporaries.
* The public functions are **synchronous for the calling process**: each call
  spawns a worker that starts the job and receives the message, so the native
  reply never lands in the caller's mailbox. A `timeout:` returns at once;
  the worker waits out the native job and deletes its output (an abandon
  handshake decides deterministically whether the caller got the result or
  `:timeout`). Screens call it from a task.
* Android resamples and downmixes in Kotlin with the integer algorithm in
  `MobMedia.PCM`, so the device output is byte-identical to the Elixir
  reference that `MobMedia.Engine.Fake` and the host tests use. iOS lets
  `AVAssetReader` convert (LinearPCM output settings), which is what the
  platform is for and has a better filter.

## Consequences

* No scheduler is ever held by decoding; native memory stays bounded however
  long the file; `to:` makes hour-long recordings practical (read 30 s windows
  with `:file.pread/3`).
* Every operation does a file round trip, even a 50 KB JPEG. That's a few
  milliseconds against a decode that takes far longer.
* The output directory must be writable: `Mob.Storage.dir(:temp)` on device,
  `config :mob_media, :tmp_dir` to override.
* Android's box-filter downsampling is cruder than Core Audio's; whisper
  doesn't care (device PCM correlates 0.999 with ffmpeg's resampler on
  speech), but a music use would want a better filter in both `PCM` and
  `PcmSink`.
