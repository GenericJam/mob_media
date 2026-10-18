defmodule MobMedia.Engine.Fake do
  @moduledoc """
  A device-free engine for host tests and agents.

      # config/test.exs
      config :mob_media, engine: MobMedia.Engine.Fake

  It goes through the same `MobMedia` code as the platform engine (the
  worker, the timeout, the temporary files), so a test sees exactly what a
  phone would return for the same answer.

    * **WAV files are decoded for real**: `info` reports their duration and
      `audio_pcm` converts them with `MobMedia.PCM.convert/5`, so a test can
      feed a recording through to transcription. 16-bit PCM only. A WAV has no
      video: `frame` is `{:error, :no_video}`.
    * **Any path can be scripted** with `script/2`, which wins over the file's
      contents: give it the info, the audio and the frame it should answer
      with. That's how a test pretends a `.mp4` or `.m4a` exists.
    * Everything else is `{:error, :unsupported}`.

  Results are delivered from another process, as the platform engine does.
  """
  @behaviour MobMedia.Engine

  alias MobMedia.PCM

  @key __MODULE__

  @typedoc "A scripted answer for a path; see `script/2`."
  @type script :: [
          info: map() | {:error, term()},
          audio: {binary(), pos_integer(), pos_integer()} | {:error, term()},
          frame: {binary(), pos_integer(), pos_integer()} | {:error, term()},
          delay: non_neg_integer()
        ]

  @doc """
  Script the answers for `path` (it must still exist: `MobMedia` checks that
  first).

    * `:info` — a map merged into `%{duration_ms: nil, width: nil,
      height: nil, has_audio: false, has_video: false, mime: nil}`, or
      `{:error, reason}`.
    * `:audio` — `{pcm, rate, channels}`, s16le, converted to whatever
      `MobMedia.audio_pcm/2` asks for; or `{:error, reason}`. Default
      `{:error, :no_audio}`.
    * `:frame` — `{jpeg, width, height}`, returned as is whatever the
      options; or `{:error, reason}`. Default `{:error, :no_video}`.
    * `:delay` — milliseconds before each answer (to exercise timeouts).
  """
  @spec script(Path.t(), script()) :: :ok
  def script(path, answers) when is_binary(path) and is_list(answers) do
    :persistent_term.put({@key, path}, answers)
  end

  @doc "Forget every scripted path."
  @spec reset() :: :ok
  def reset do
    for {{@key, _} = key, _} <- :persistent_term.get(), do: :persistent_term.erase(key)
    :ok
  end

  @impl true
  def info(ref, path), do: deliver(ref, path, &answer_info/1)

  @impl true
  def audio_pcm(ref, path, out, rate, channels),
    do: deliver(ref, path, &answer_audio(&1, out, rate, channels))

  @impl true
  def frame(ref, path, out, _at_ms, _max_px, _quality),
    do: deliver(ref, path, &answer_frame(&1, out))

  @impl true
  def available?, do: true

  @impl true
  def tmp_dir, do: System.tmp_dir!()

  defp deliver(ref, path, answer) do
    caller = self()
    source = source(path)
    delay = if match?({:script, _}, source), do: Keyword.get(elem(source, 1), :delay, 0), else: 0

    spawn(fn ->
      Process.sleep(delay)
      send(caller, {:mob_media, ref, answer.(source)})
    end)

    :ok
  end

  defp source(path) do
    case :persistent_term.get({@key, path}, nil) do
      nil -> wav(path)
      answers -> {:script, answers}
    end
  end

  defp wav(path) do
    with {:ok, data} <- File.read(path),
         {:ok, wav} <- PCM.parse_wav(data) do
      {:wav, wav}
    else
      _ -> :unsupported
    end
  end

  defp answer_info({:script, answers}) do
    case Keyword.get(answers, :info, %{}) do
      {:error, _} = error ->
        error

      info ->
        info = Map.merge(%{duration_ms: nil, width: nil, height: nil, mime: nil}, info)

        {:ok,
         {info.duration_ms || -1, info.width || 0, info.height || 0,
          Map.get(info, :has_audio, false), Map.get(info, :has_video, false), info.mime || ""}}
    end
  end

  defp answer_info({:wav, %{pcm: pcm, rate: rate, channels: channels}}),
    do: {:ok, {PCM.duration_ms(pcm, rate, channels), 0, 0, true, false, "audio/wav"}}

  defp answer_info(:unsupported), do: {:error, :unsupported}

  defp answer_audio({:script, answers}, out, rate, channels) do
    case Keyword.get(answers, :audio, {:error, :no_audio}) do
      {:error, _} = error ->
        error

      {pcm, in_rate, in_channels} ->
        write(out, PCM.convert(pcm, in_rate, in_channels, rate, channels))
    end
  end

  defp answer_audio({:wav, wav}, out, rate, channels),
    do: write(out, PCM.convert(wav.pcm, wav.rate, wav.channels, rate, channels))

  defp answer_audio(:unsupported, _out, _rate, _channels), do: {:error, :unsupported}

  defp answer_frame({:script, answers}, out) do
    case Keyword.get(answers, :frame, {:error, :no_video}) do
      {:error, _} = error ->
        error

      {jpeg, width, height} ->
        with {:ok, _bytes} <- write(out, jpeg), do: {:ok, {width, height}}
    end
  end

  defp answer_frame({:wav, _}, _out), do: {:error, :no_video}
  defp answer_frame(:unsupported, _out), do: {:error, :unsupported}

  defp write(out, data) do
    case File.write(out, data) do
      :ok -> {:ok, byte_size(data)}
      {:error, _} -> {:error, :io_error}
    end
  end
end
