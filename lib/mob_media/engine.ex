defmodule MobMedia.Engine do
  @moduledoc """
  What does the decoding behind `MobMedia`. The callbacks mirror the NIF
  (`:mob_media_nif`) one for one, so every engine speaks the same contract.

  Shipped engines:

    * `MobMedia.Engine.Native` — the platform decoders (the default when the
      NIF is linked into the app).
    * `MobMedia.Engine.Fake` — no device: decodes WAV files in Elixir and plays
      back scripted results for any other path. For host tests and agents.
    * `MobMedia.Engine.Unavailable` — answers `{:error, :unavailable}` (the
      default when the NIF isn't linked, e.g. on the host).

  Pick one with `config :mob_media, engine: Module`.

  ## The contract

  Each operation is called in a short-lived worker process that `MobMedia`
  owns, with a fresh `ref`. It returns at once: `:ok` when the work was
  started, or `{:error, reason}` when it couldn't be. After `:ok` the engine
  sends that process **exactly one** message, from any process or thread:

      {:mob_media, ref, {:ok, {duration_ms, width, height, has_audio, has_video, mime}}}  # info/2
      {:mob_media, ref, {:ok, bytes_written}}                                            # audio_pcm/5
      {:mob_media, ref, {:ok, {width, height}}}                                          # frame/6
      {:mob_media, ref, {:error, reason}}

  `duration_ms` is `-1` when unknown, `width`/`height` are `0` without video
  and `mime` is `""` when unknown. `audio_pcm/5` writes signed 16-bit
  little-endian interleaved PCM to `out`; `frame/6` writes a JPEG there.
  The engine never deletes or renames `out`: `MobMedia` owns the files.

  `path` exists (checked before the call). Reasons: `:unsupported` (not a
  format the platform can open or decode), `:no_audio`, `:no_video`,
  `:decode_failed` (the decoder failed part way), `:io_error` (couldn't
  write `out`), `:not_found`.
  """

  @typedoc "What the engine delivers in `{:mob_media, ref, result}`."
  @type result ::
          {:ok, {integer(), non_neg_integer(), non_neg_integer(), boolean(), boolean(), binary()}}
          | {:ok, non_neg_integer()}
          | {:ok, {pos_integer(), pos_integer()}}
          | {:error, term()}

  @doc "Read the duration, dimensions, tracks and MIME type of `path`."
  @callback info(ref :: reference(), path :: binary()) :: :ok | {:error, term()}

  @doc """
  Decode the first audio track of `path` to `rate` Hz, `channels`-channel
  s16le PCM written to `out`.
  """
  @callback audio_pcm(
              ref :: reference(),
              path :: binary(),
              out :: binary(),
              rate :: pos_integer(),
              channels :: 1 | 2
            ) :: :ok | {:error, term()}

  @doc """
  Write the video frame of `path` at `at_ms` (clamped to the duration) as a
  JPEG of `quality` (1..100) to `out`, scaled down so neither side exceeds
  `max_px` (`0`: full size).
  """
  @callback frame(
              ref :: reference(),
              path :: binary(),
              out :: binary(),
              at_ms :: non_neg_integer(),
              max_px :: non_neg_integer(),
              quality :: 1..100
            ) :: :ok | {:error, term()}

  @doc "Whether this engine can do any work here."
  @callback available?() :: boolean()

  @doc "A writable directory for the engine's temporary output files."
  @callback tmp_dir() :: Path.t()
end
