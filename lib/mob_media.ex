defmodule MobMedia do
  @moduledoc """
  Media helpers for Mob apps, through the platform's own decoders: what's in
  a media file, its audio as PCM for speech-to-text, and a video frame as a
  JPEG.

      {:ok, %{duration_ms: 12_480, has_video: true, width: 1080, height: 1920}} =
        MobMedia.info(path)

      {:ok, pcm} = MobMedia.audio_pcm(path)          # 16 kHz mono s16le
      {:ok, text} = MobWhisper.transcribe(pcm)

      {:ok, jpeg} = MobMedia.frame(path, 4_000, max_px: 1024)

  Android decodes with `MediaExtractor` + `MediaCodec` and grabs frames with
  `MediaMetadataRetriever`; iOS uses `AVAssetReader` and
  `AVAssetImageGenerator`. Anything the platform's decoders handle works
  (verified on both: m4a/AAC, mp3, wav, ogg/opus, mp4/H.264). No
  ffmpeg, no permission: `path` is a local file the app can already read
  (from `Mob.Files.pick/2`, mob_photos, mob_camera, `Mob.Audio`, ...), not a
  `content://` URI.

  ## Sync, off the schedulers

  Every function blocks **the calling process** until the answer is ready and
  returns it. The work itself runs on a native thread (a Kotlin thread pool on
  Android, a GCD queue on iOS); the NIF only queues it and returns, and the
  native side sends the result back as a message. No BEAM scheduler, normal or
  dirty, is held while a file decodes.

  Decoding a long recording takes a while (10-30% of its length on a
  mid-range Android phone), so don't call `audio_pcm/2` from a screen's
  `handle_event`/`handle_info` directly: the screen would stop answering
  taps until it returns. Run it in a task and send yourself the result:

      screen = self()
      Task.start(fn -> send(screen, {:pcm_ready, MobMedia.audio_pcm(path)}) end)

  Each call runs in its own short-lived process, so a call that times out
  (`:timeout` option) returns `{:error, :timeout}` at once while the native
  work finishes in the background and its temporary output is deleted. A
  caller that dies is handled the same way.

  ## Memory

  `audio_pcm/2` never holds the whole decode in native memory: the platform
  side streams the PCM into a file as it decodes. Without `:to`, that file is
  temporary and is read into the binary `audio_pcm/2` returns (16 kHz mono is
  1.9 MB a minute, 115 MB an hour). For long recordings pass `to: path`: the
  PCM stays in that file (`{:ok, path}`), and you can read it a window at a
  time (whisper works in 30 s windows: 960 000 bytes at 16 kHz mono):

      {:ok, pcm_path} = MobMedia.audio_pcm(video, to: Path.join(dir, "audio.pcm"))
      {:ok, fd} = :file.open(pcm_path, [:read, :binary, :raw])
      {:ok, window} = :file.pread(fd, 0, 960_000)

  ## Errors

    * `:not_found` — `path` doesn't exist.
    * `:unsupported` — not a format the platform can open or decode.
    * `:no_audio` / `:no_video` — the file has no such track.
    * `:decode_failed` — the decoder failed part way (a damaged file).
    * `:io_error` — the output couldn't be written or read back.
    * `:timeout` — the `:timeout` option ran out.
    * `:unavailable` — the NIF isn't linked into this build (or you're on the
      host without `MobMedia.Engine.Fake`).
    * `{:jni, reason}` (Android) / `:alloc` (iOS) — the NIF couldn't queue
      the job; see `MobMedia.Engine.Native`.

  ## Engines

  The decoding is done by a `MobMedia.Engine`: `MobMedia.Engine.Native` when
  the NIF is linked, `MobMedia.Engine.Unavailable` otherwise. Tests and
  agents use `MobMedia.Engine.Fake` (real WAV decoding, scripted answers for
  anything else):

      config :mob_media, engine: MobMedia.Engine.Fake
  """

  alias MobMedia.Engine

  @typedoc "What `info/2` returns. Fields the file doesn't have are `nil`."
  @type info :: %{
          duration_ms: non_neg_integer() | nil,
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          has_audio: boolean(),
          has_video: boolean(),
          mime: String.t() | nil
        }

  @typedoc "Why an operation failed; see the moduledoc."
  @type reason ::
          :not_found
          | :unsupported
          | :no_audio
          | :no_video
          | :decode_failed
          | :io_error
          | :timeout
          | :unavailable
          | {:jni, atom()}
          | term()

  @default_rate 16_000
  @default_channels 1
  @default_max_px 1280
  @default_quality 85

  # Aliases the platforms report for the same container, folded to one name.
  @mime_aliases %{
    "audio/x-wav" => "audio/wav",
    "audio/wave" => "audio/wav",
    "audio/vnd.wave" => "audio/wav",
    "audio/x-m4a" => "audio/mp4",
    "audio/m4a" => "audio/mp4",
    "audio/mp3" => "audio/mpeg",
    "audio/x-mpeg" => "audio/mpeg",
    "audio/x-aac" => "audio/aac"
  }

  @doc """
  Duration, video dimensions, which tracks the file has, and its MIME type.

      {:ok, %{duration_ms: 3_021, width: nil, height: nil,
              has_audio: true, has_video: false, mime: "audio/mp4"}}

  `width`/`height` are the size the video is **shown** at: a portrait phone
  video recorded as 1920x1080 with a 90° rotation reports 1080x1920, the same
  orientation `frame/3` returns. `mime` is the container type as the platform
  reports it (common aliases folded: `audio/x-wav` is `audio/wav`,
  `audio/x-m4a` is `audio/mp4`), or `nil`.

  Options: `:timeout` (ms, default `:infinity`).
  """
  @spec info(Path.t(), keyword()) :: {:ok, info()} | {:error, reason()}
  def info(path, opts \\ []) when is_binary(path) and is_list(opts) do
    run(path, timeout!(opts), %{
      start: fn engine, ref, nil -> engine.info(ref, path) end,
      output: nil
    })
  end

  @doc """
  Decode the audio of `path` (an audio file, or a video's audio track) to
  signed 16-bit little-endian interleaved PCM, the format
  `MobWhisper.transcribe/2` takes.

  Options:

    * `:rate` — sample rate in Hz (default #{@default_rate}).
    * `:channels` — `1` (default; channels averaged) or `2`.
    * `:to` — write the PCM to this file instead of returning it, and return
      `{:ok, to}`. The file appears only when the decode succeeded (it's
      written beside it and renamed). See "Memory" in the moduledoc.
    * `:timeout` — ms, default `:infinity`.

  `{:error, :no_audio}` when the file has no audio track. The PCM covers the
  whole track: its length (`MobMedia.PCM.duration_ms/3`) matches the duration
  within a few tens of milliseconds (codec priming and padding).
  """
  @spec audio_pcm(Path.t(), keyword()) :: {:ok, binary() | Path.t()} | {:error, reason()}
  def audio_pcm(path, opts \\ []) when is_binary(path) and is_list(opts) do
    rate = opt!(opts, :rate, @default_rate, &(is_integer(&1) and &1 in 1_000..384_000))
    channels = opt!(opts, :channels, @default_channels, &(&1 in [1, 2]))
    to = opt!(opts, :to, nil, &(is_nil(&1) or (is_binary(&1) and &1 != "")))

    run(path, timeout!(opts), %{
      start: fn engine, ref, out -> engine.audio_pcm(ref, path, out, rate, channels) end,
      output: if(to, do: {:file, to}, else: {:binary, "pcm"})
    })
  end

  @doc """
  The video frame of `path` at `at_ms` milliseconds, as a JPEG binary.

  The frame is the one shown at that time (exact, not the nearest keyframe),
  upright (the video's rotation applied), scaled down so neither side exceeds
  `:max_px`. A time past the end gives the last frame.

  Options:

    * `:max_px` — longest side in pixels (default #{@default_max_px}); never
      scales up. `nil` keeps the full size.
    * `:quality` — JPEG quality 1..100 (default #{@default_quality}).
    * `:timeout` — ms, default `:infinity`.

  `{:error, :no_video}` for a file without a video track.
  """
  @spec frame(Path.t(), non_neg_integer(), keyword()) :: {:ok, binary()} | {:error, reason()}
  def frame(path, at_ms, opts \\ [])
      when is_binary(path) and is_integer(at_ms) and at_ms >= 0 and is_list(opts) do
    max_px =
      opt!(opts, :max_px, @default_max_px, &(is_nil(&1) or (is_integer(&1) and &1 > 0)))

    quality = opt!(opts, :quality, @default_quality, &(is_integer(&1) and &1 in 1..100))

    run(path, timeout!(opts), %{
      start: fn engine, ref, out ->
        engine.frame(ref, path, out, at_ms, max_px || 0, quality)
      end,
      output: {:binary, "jpg"}
    })
  end

  @doc "Whether media can be decoded in this build (the NIF is linked, or an engine is configured)."
  @spec available?() :: boolean()
  def available?, do: engine().available?()

  @doc """
  The engine in use: `config :mob_media, :engine` if set, otherwise
  `MobMedia.Engine.Native` when the NIF is linked, otherwise
  `MobMedia.Engine.Unavailable`.
  """
  @spec engine() :: module()
  def engine do
    case Application.get_env(:mob_media, :engine) do
      nil -> if :mob_media_nif.available(), do: Engine.Native, else: Engine.Unavailable
      engine -> engine
    end
  end

  # ── Options ──────────────────────────────────────────────────────────────

  defp opt!(opts, key, default, valid?) do
    value = Keyword.get(opts, key, default)

    if valid?.(value),
      do: value,
      else: raise(ArgumentError, "invalid #{inspect(key)} option: #{inspect(value)}")
  end

  defp timeout!(opts),
    do:
      opt!(
        opts,
        :timeout,
        :infinity,
        &(&1 == :infinity or (is_integer(&1) and &1 >= 0))
      )

  # ── Results and output files ─────────────────────────────────────────────
  #
  # An op's :output says where the native side writes and what the caller
  # gets: nil (info: nothing written), {:binary, ext} (a temporary file in the
  # engine's tmp_dir, read back and deleted) or {:file, to} (written beside
  # `to` and renamed onto it on success, so `to` never holds a partial file).

  defp out_path(nil, _engine), do: nil

  defp out_path({:binary, ext}, engine) do
    dir = Application.get_env(:mob_media, :tmp_dir) || engine.tmp_dir()
    File.mkdir_p(dir)
    Path.join(dir, "mob_media-#{unique()}.#{ext}")
  end

  defp out_path({:file, to}, _engine), do: "#{to}.mob_media-#{unique()}.part"

  defp unique, do: "#{System.os_time(:microsecond)}-#{System.unique_integer([:positive])}"

  defp cleanup(nil), do: :ok

  defp cleanup(out) do
    File.rm(out)
    :ok
  end

  defp finish(result, nil, nil), do: info_result(result)

  defp finish({:ok, _}, {:binary, _}, out) do
    result = File.read(out)
    cleanup(out)

    case result do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:error, :io_error}
    end
  end

  defp finish({:ok, _}, {:file, to}, out) do
    case File.rename(out, to) do
      :ok ->
        {:ok, to}

      {:error, _} ->
        cleanup(out)
        {:error, :io_error}
    end
  end

  defp finish({:error, _} = error, _output, out) do
    cleanup(out)
    error
  end

  defp info_result({:ok, {duration_ms, width, height, has_audio, has_video, mime}}) do
    {:ok,
     %{
       duration_ms: if(duration_ms >= 0, do: duration_ms),
       width: if(has_video and width > 0, do: width),
       height: if(has_video and height > 0, do: height),
       has_audio: has_audio,
       has_video: has_video,
       mime: mime(mime)
     }}
  end

  defp info_result({:error, _} = error), do: error

  defp mime(""), do: nil

  defp mime(mime) do
    mime = String.downcase(mime)
    Map.get(@mime_aliases, mime, mime)
  end

  # ── The worker ───────────────────────────────────────────────────────────
  #
  # Each call runs in a fresh process that starts the engine's job (so the
  # native reply lands in its mailbox, not the caller's) and owns the output
  # file. It answers the caller with {tag, result}. On timeout the caller
  # sends {:abandon, tag} and waits for either the result (the worker was
  # already finishing) or :abandoned; an abandoned worker, or one whose caller
  # died, still waits for the engine's one reply and then deletes the output.

  defp run(path, timeout, op) do
    engine = engine()

    cond do
      not engine.available?() ->
        {:error, :unavailable}

      not File.exists?(path) ->
        {:error, :not_found}

      true ->
        caller = self()
        tag = make_ref()
        {pid, monitor} = spawn_monitor(fn -> work(caller, tag, engine, op) end)
        await(pid, monitor, tag, timeout)
    end
  end

  defp await(pid, monitor, tag, timeout) do
    receive do
      {^tag, result} -> done(monitor, result)
      {:DOWN, ^monitor, :process, _, reason} -> {:error, {:crashed, reason}}
    after
      timeout ->
        send(pid, {:abandon, tag})

        receive do
          {^tag, :abandoned} -> done(monitor, {:error, :timeout})
          {^tag, result} -> done(monitor, result)
          {:DOWN, ^monitor, :process, _, _} -> {:error, :timeout}
        end
    end
  end

  defp done(monitor, result) do
    Process.demonitor(monitor, [:flush])
    result
  end

  defp work(caller, tag, engine, %{start: start, output: output}) do
    caller_monitor = Process.monitor(caller)
    ref = make_ref()
    out = out_path(output, engine)

    case start.(engine, ref, out) do
      :ok ->
        receive do
          {:mob_media, ^ref, result} ->
            send(caller, {tag, finish(result, output, out)})

          {:abandon, ^tag} ->
            send(caller, {tag, :abandoned})
            drain(ref, out)

          {:DOWN, ^caller_monitor, :process, _, _} ->
            drain(ref, out)
        end

      {:error, _} = error ->
        cleanup(out)
        send(caller, {tag, error})
    end
  end

  defp drain(ref, out) do
    receive do
      {:mob_media, ^ref, _} -> cleanup(out)
    end
  end
end
