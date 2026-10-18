# AGENTS.md — orientation for AI agents working on mob_media

You're in **mob_media**, a Mob plugin with three media helpers over the
platform decoders: `MobMedia.info/2`, `MobMedia.audio_pcm/2` (any audio
track to s16le PCM, e.g. for `MobWhisper.transcribe/2`) and `MobMedia.frame/3`
(a video frame as JPEG). The README has the API; this file is what you need
to change it safely.

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view
(repo topology, driving a running app) and
[`~/code/mob/guides/plugins.md`](../mob/guides/plugins.md) for signing,
activation and self-tests. Decisions are in `decisions/`.

> **Keep this file current.** When you change the result contract, either
> native side, or hit a gotcha, fix it here in the same commit.

## Anatomy

* `lib/mob_media.ex` — the public API, option checks, and the worker: each
  call spawns a process that starts the engine's job, receives its one
  `{:mob_media, ref, result}` message, owns the output file and answers the
  caller. Timeouts and dead callers are handled there (abandon handshake).
* `lib/mob_media/engine.ex` — the `MobMedia.Engine` behaviour: the NIF's
  contract, one callback per NIF function.
* `lib/mob_media/engine/native.ex` — `Native` (the NIF) and `Unavailable`.
* `lib/mob_media/engine/fake.ex` — host engine: real WAV decoding,
  `script/2` for anything else.
* `lib/mob_media/pcm.ex` — the reference channel mapping + resampler (and
  WAV read/write). **The Kotlin `PcmSink` implements the same integer
  algorithm and must stay byte-identical to it.**
* `lib/mob_media/self_test.ex`, `lib/mob_media/demo_screen.ex`.
* `src/mob_media_nif.erl` — stub; `available/0` is `false` unless the NIF
  replaced it.
* `priv/native/jni/mob_media_nif.c` — Android NIF: queues a job on the
  Kotlin bridge; `nativeDeliver*` thunks build the message.
* `priv/native/android/MobMediaBridge.kt` — Android work, two-thread pool.
* `priv/native/ios/mob_media_nif.m` — iOS NIF and work (an `NSOperationQueue`,
  two jobs at a time).

## The contract (four places, change together)

`MobMedia.Engine` moduledoc, `src/mob_media_nif.erl` header, both native
files' headers. Messages: `{mob_media, Ref, {ok, {DurMs, W, H, HasAudio,
HasVideo, Mime}}}` / `{ok, Bytes}` / `{ok, {W, H}}` / `{error, Reason}`.
Android error codes are `MobMediaBridge.E_*` = index into `mm_reasons` in
the C file; add a code on both sides or the wrong atom is delivered.

## Rules that matter here

1. **No decoding on a BEAM scheduler.** The NIFs only queue. A Mob app has
   one dirty CPU and one dirty IO scheduler; don't switch to dirty NIFs.
2. **Exactly one delivery per queued job.** Kotlin: `submit` catches
   everything and always calls one `nativeDeliver*`; if `start` throws, the C
   side frees the job. iOS: every path in a job block ends in `mm_send`. A
   missing delivery leaks the job and hangs the worker process forever.
3. **Files, not big binaries, across the boundary.** Native writes to the
   `out` path Elixir chose; Elixir reads/renames/deletes. See
   `decisions/2026-10-18-native-writes-files.md`.
4. **Paths cross JNI as UTF-8 byte arrays**, never `NewStringUTF`.
5. **`PcmSink` ↔ `MobMedia.PCM` parity.** Change the algorithm in both and
   re-run the device parity check (WAVs at 8 kHz mono, 11.025 kHz stereo,
   48 kHz 5.1 → several rates; device bytes must equal `PCM.convert/5`).
6. **Native changes need a native build and devices.** `mix test` covers the
   Elixir half only; CI syntax-checks the C, the Objective-C and compiles the
   Kotlin against android.jar. Re-verify with a host app on the moto g 2021
   (ZY22DP6HFL; never ZY22K6BSJM) or an emulator and an iOS simulator:
   `mix mob.deploy --native`, `mix mob.selftest`, and the demo screen.
   Take an `agent-lease` first. On the moto g 2021 another app's BEAM
   (com.genericjam.operator) may hold port 4369, which breaks `mob.connect`'s
   `adb reverse`; force-stop it for the session and relaunch it after.
7. **Hot pushes reload the NIF stub.** After `mix mob.deploy` (no
   `--native`) hot-loads `mob_media_nif`, the app sees `available/0 = false`
   until it restarts (`mix mob.connect` restarts it).
8. **No compile-time `~r//` literals** in `lib/` (the device runs OTP 28).

## Testing

```bash
mix test
mix format --check-formatted
mix credo --strict
mix compile --warnings-as-errors
mix mob.validate_plugin
```

## Release

Version bumps and Hex publishes need Kevin's approval. `.github/workflows/release.yml`
(mob_dev's plugin scaffold workflow) publishes on any push to master that
changes `mix.exs`: it tags `<version>`, creates the GitHub Release from the
CHANGELOG section, and, unless the version is on Hex, checks that
`MOB_PLUGIN_SIGN_KEY` (the shared first-party key; `priv/mob_plugin.pub` is its
public half, fingerprint `ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=`)
derives the committed public key, validates, signs and runs
`mix hex.publish`. It needs the `HEX_API_KEY` and `MOB_PLUGIN_SIGN_KEY`
secrets. To release: move `[Unreleased]` to `## [x.y.z] - date` and bump
`@version` in the same commit. Never commit `priv/mob_plugin.sig`.
