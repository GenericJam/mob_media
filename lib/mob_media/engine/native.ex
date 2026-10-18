defmodule MobMedia.Engine.Native do
  @moduledoc """
  The platform decoders, through the `:mob_media_nif` NIF linked into the app
  by its native build.

    * Android: the C NIF hands each job to the Kotlin `MobMediaBridge`, which
      runs it on its own two-thread pool: `MediaExtractor` + `MediaCodec` for
      PCM (downmixed and resampled in Kotlin, the same algorithm as
      `MobMedia.PCM`), `MediaExtractor` + `MediaMetadataRetriever` for info,
      `MediaMetadataRetriever.getScaledFrameAtTime` for frames.
    * iOS: the Objective-C NIF runs each job on a GCD queue:
      `AVAssetReader` with LinearPCM output settings at the requested rate
      and channels (Core Audio does the conversion), `AVAssetImageGenerator`
      for frames, `AVURLAsset` for info.

  No BEAM scheduler (normal or dirty) runs any decoding; a Mob app has one
  dirty CPU and one dirty IO scheduler and they're not ours to hold.

  Synchronous errors on Android are `{:error, {:jni, reason}}`: `:no_jenv`,
  `:bridge_not_registered` (`MobMediaBridge.register()` didn't run before the
  BEAM started), `:alloc` or `:call_failed` (the bridge threw; it logs why
  under the `MobMedia` logcat tag). On iOS the only one is `{:error, :alloc}`
  (the job couldn't be allocated).
  """
  @behaviour MobMedia.Engine

  @impl true
  def info(ref, path), do: :mob_media_nif.info(ref, path)

  @impl true
  def audio_pcm(ref, path, out, rate, channels),
    do: :mob_media_nif.audio_pcm(ref, path, out, rate, channels)

  @impl true
  def frame(ref, path, out, at_ms, max_px, quality),
    do: :mob_media_nif.frame(ref, path, out, at_ms, max_px, quality)

  @impl true
  def available?, do: :mob_media_nif.available()

  @impl true
  def tmp_dir, do: Mob.Storage.dir(:temp)
end

defmodule MobMedia.Engine.Unavailable do
  @moduledoc """
  The engine when the app was built without the NIF (and on the host, unless
  `MobMedia.Engine.Fake` is configured): every operation is
  `{:error, :unavailable}`.
  """
  @behaviour MobMedia.Engine

  @impl true
  def info(_ref, _path), do: {:error, :unavailable}

  @impl true
  def audio_pcm(_ref, _path, _out, _rate, _channels), do: {:error, :unavailable}

  @impl true
  def frame(_ref, _path, _out, _at_ms, _max_px, _quality), do: {:error, :unavailable}

  @impl true
  def available?, do: false

  @impl true
  def tmp_dir, do: System.tmp_dir!()
end
