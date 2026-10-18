defmodule MobMedia.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  It writes a one-second 44.1 kHz stereo WAV of a 440 Hz tone, then through
  the NIF (`MobMedia.Engine.Native`):

    1. `MobMedia.info/2` must report audio, no video, and a duration within
       50 ms of 1000;
    2. `MobMedia.audio_pcm/2` must decode it to 16 kHz mono: 32 000 bytes
       (within 50 ms) of audible signal. On Android that's `MediaExtractor`,
       a `MediaCodec` raw decoder and the bridge's downmix and resampler; on
       iOS `AVAssetReader` with LinearPCM output settings;
    3. `MobMedia.frame/3` on it must answer `{:error, :no_video}`, which takes
       a real look at the file's tracks.

  The WAV is deleted afterwards. There is no skip: no hardware, permission or
  network is involved, so every device and simulator gives the full answer.
  """
  @behaviour Mob.Plugin.SelfTest

  alias MobMedia.PCM

  @timeout 15_000

  @impl true
  def run(ctx), do: run(ctx, [])

  @doc false
  # Options: `:dir` for the WAV (default the engine's tmp_dir), `:engine` to
  # require (default MobMedia.Engine.Native; unit tests pass the fake).
  @spec run(Mob.Plugin.SelfTest.ctx(), keyword()) :: Mob.Plugin.SelfTest.result()
  def run(%{platform: platform}, opts) do
    required = Keyword.get(opts, :engine, MobMedia.Engine.Native)

    case MobMedia.engine() do
      ^required ->
        dir = Keyword.get_lazy(opts, :dir, &required.tmp_dir/0)
        File.mkdir_p!(dir)
        path = Path.join(dir, "mob_media_selftest_#{System.unique_integer([:positive])}.wav")
        File.write!(path, tone_wav())

        try do
          check(path, platform)
        after
          File.rm(path)
        end

      other ->
        {:fail,
         "MobMedia.engine() on #{platform} is #{inspect(other)}, expected #{inspect(required)}: " <>
           "the mob_media NIF isn't linked into this build (or :mob_media, :engine is set)"}
    end
  end

  defp check(path, platform) do
    with {:info, {:ok, %{has_audio: true, has_video: false, duration_ms: ms}}}
         when ms in 950..1050 <- {:info, MobMedia.info(path, timeout: @timeout)},
         {:audio_pcm, {:ok, pcm}} when byte_size(pcm) in 30_400..33_600 <-
           {:audio_pcm, MobMedia.audio_pcm(path, timeout: @timeout)},
         {:loud, true} <- {:loud, peak(pcm) > 4_000},
         {:frame, {:error, :no_video}} <- {:frame, MobMedia.frame(path, 0, timeout: @timeout)} do
      :pass
    else
      {:audio_pcm, {:ok, pcm}} ->
        {:fail,
         "audio_pcm/2 on #{platform} decoded a 1 s WAV to #{byte_size(pcm)} bytes of " <>
           "16 kHz mono, expected about 32000"}

      {:loud, false} ->
        {:fail, "audio_pcm/2 on #{platform} decoded a loud 440 Hz tone to near silence"}

      {step, result} ->
        {:fail, "#{step} on #{platform} returned #{inspect(result)} for a 1 s 44.1 kHz WAV"}
    end
  end

  defp peak(pcm) do
    for <<s::little-signed-16 <- pcm>>, reduce: 0, do: (acc -> max(acc, abs(s)))
  end

  @doc false
  # One second of a 440 Hz tone, 44.1 kHz stereo, as a WAV file.
  @spec tone_wav() :: binary()
  def tone_wav do
    pcm =
      for i <- 0..(44_100 - 1), into: <<>> do
        s = round(16_000 * :math.sin(2 * :math.pi() * 440 * i / 44_100))
        <<s::little-signed-16, s::little-signed-16>>
      end

    PCM.wav(pcm, 44_100, 2)
  end
end
