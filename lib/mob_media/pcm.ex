defmodule MobMedia.PCM do
  @moduledoc """
  Helpers for signed 16-bit little-endian interleaved PCM, the format
  `MobMedia.audio_pcm/2` returns, plus the reference conversion the Android
  decoder implements and `MobMedia.Engine.Fake` uses.

  ## Conversion

  `convert/5` maps channels, then resamples each channel:

    * **Channels.** Same count: unchanged. To mono: the average of every
      channel (truncated). Mono to stereo: the sample on both sides. More
      than two channels to stereo: the first two (front left, front right).
    * **Downsampling** (`in_rate > out_rate`): output frame `k` is the average
      of input frames `floor(k * in / out)` up to, not including,
      `floor((k + 1) * in / out)`: a box filter, which is enough of a
      low-pass for speech recognition. A box is emitted once all of its input
      frames exist.
    * **Upsampling** (`in_rate < out_rate`): output frame `k` sits at input
      position `k * in / out` and is linearly interpolated between its two
      neighbours (the last input frame stands alone), rounded half up.
      Emitted while that position is inside the input.

  So `n` input frames give about `n * out / in` output frames (within one).
  iOS uses Core Audio's own converter instead, so its samples differ
  slightly; the length is the same within a few milliseconds.

  This is integer arithmetic only, so a streaming implementation (the Kotlin
  bridge converts one decoder buffer at a time) produces exactly the same
  samples as this one.
  """

  @doc "Length of `pcm` in milliseconds at `rate` Hz and `channels` channels (rounded down)."
  @spec duration_ms(binary(), pos_integer(), pos_integer()) :: non_neg_integer()
  def duration_ms(pcm, rate, channels)
      when is_binary(pcm) and is_integer(rate) and rate > 0 and is_integer(channels) and
             channels > 0 do
    div(byte_size(pcm) * 1000, 2 * rate * channels)
  end

  @doc """
  Convert `pcm` from `in_rate` Hz / `in_channels` to `out_rate` Hz /
  `out_channels` (1 or 2). See the moduledoc for the algorithm. A trailing
  partial frame is dropped.
  """
  @spec convert(binary(), pos_integer(), pos_integer(), pos_integer(), 1 | 2) :: binary()
  def convert(pcm, in_rate, in_channels, out_rate, out_channels)
      when is_binary(pcm) and is_integer(in_rate) and in_rate > 0 and is_integer(in_channels) and
             in_channels > 0 and is_integer(out_rate) and out_rate > 0 and
             out_channels in [1, 2] do
    pcm
    |> frames(in_channels)
    |> Enum.map(&map_channels(&1, out_channels))
    |> transpose(out_channels)
    |> Enum.map(&resample(&1, in_rate, out_rate))
    |> interleave()
  end

  defp frames(pcm, channels) do
    samples = for <<s::little-signed-16 <- pcm>>, do: s
    Enum.chunk_every(samples, channels, channels, :discard)
  end

  defp map_channels([s], 2), do: [s, s]
  defp map_channels(frame, 1), do: [div(Enum.sum(frame), length(frame))]
  defp map_channels([l, r | _], 2), do: [l, r]

  defp transpose([], channels), do: List.duplicate([], channels)
  defp transpose(frames, _channels), do: frames |> Enum.zip() |> Enum.map(&Tuple.to_list/1)

  defp interleave(channels) do
    channels
    |> Enum.zip()
    |> Enum.map(&Tuple.to_list/1)
    |> List.flatten()
    |> Enum.into(<<>>, &<<&1::little-signed-16>>)
  end

  @doc false
  # One channel's samples, resampled from in_rate to out_rate.
  @spec resample([integer()], pos_integer(), pos_integer()) :: [integer()]
  def resample(samples, rate, rate), do: samples

  def resample(samples, in_rate, out_rate) when in_rate > out_rate,
    do: boxes(samples, 0, 0, length(samples), in_rate, out_rate, [])

  def resample(samples, in_rate, out_rate) do
    n = length(samples)
    input = List.to_tuple(samples)

    Stream.iterate(0, &(&1 + 1))
    |> Stream.take_while(&(&1 * in_rate < n * out_rate))
    |> Enum.map(&interpolate(input, n, &1 * in_rate, out_rate))
  end

  # Box k spans input frames [floor(k*in/out), floor((k+1)*in/out)).
  defp boxes(samples, k, start, n, in_rate, out_rate, acc) do
    stop = div((k + 1) * in_rate, out_rate)

    if stop > n do
      Enum.reverse(acc)
    else
      {box, rest} = Enum.split(samples, stop - start)
      boxes(rest, k + 1, stop, n, in_rate, out_rate, [div(Enum.sum(box), length(box)) | acc])
    end
  end

  # Output at input position pos/out_rate: between frames j and j + 1.
  defp interpolate(input, n, pos, out_rate) do
    j = div(pos, out_rate)
    num = pos - j * out_rate
    a = elem(input, j)
    b = if j + 1 < n, do: elem(input, j + 1), else: a
    a + Integer.floor_div(2 * (b - a) * num + out_rate, 2 * out_rate)
  end

  @doc """
  A WAV file (RIFF, 16-bit PCM) holding `pcm` at `rate` Hz with `channels`
  channels.
  """
  @spec wav(binary(), pos_integer(), pos_integer()) :: binary()
  def wav(pcm, rate, channels) when is_binary(pcm) do
    fmt =
      <<1::little-16, channels::little-16, rate::little-32, rate * channels * 2::little-32,
        channels * 2::little-16, 16::little-16>>

    body =
      "WAVE" <>
        chunk("fmt ", fmt) <>
        chunk("data", pcm)

    "RIFF" <> <<byte_size(body)::little-32>> <> body
  end

  defp chunk(id, data) do
    pad = if rem(byte_size(data), 2) == 1, do: <<0>>, else: <<>>
    id <> <<byte_size(data)::little-32>> <> data <> pad
  end

  @doc """
  Parse a WAV file holding 16-bit integer PCM (format 1, or
  `WAVE_FORMAT_EXTENSIBLE` with the PCM subformat).
  `{:error, :unsupported}` for anything else.
  """
  @spec parse_wav(binary()) ::
          {:ok, %{rate: pos_integer(), channels: pos_integer(), pcm: binary()}}
          | {:error, :unsupported}
  def parse_wav(<<"RIFF", _size::little-32, "WAVE", chunks::binary>>) do
    with {:ok, fmt} <- find_chunk(chunks, "fmt "),
         {:ok, rate, channels} <- pcm16_format(fmt),
         {:ok, data} <- find_chunk(chunks, "data") do
      usable = byte_size(data) - rem(byte_size(data), 2 * channels)
      {:ok, %{rate: rate, channels: channels, pcm: binary_part(data, 0, usable)}}
    end
  end

  def parse_wav(_), do: {:error, :unsupported}

  defp find_chunk(<<id::binary-4, size::little-32, rest::binary>>, want) do
    if id == want do
      # A truncated last chunk (e.g. a recording cut off) keeps what's there.
      {:ok, binary_part(rest, 0, min(size, byte_size(rest)))}
    else
      # Chunks are padded to an even length.
      skip = min(size + rem(size, 2), byte_size(rest))
      find_chunk(binary_part(rest, skip, byte_size(rest) - skip), want)
    end
  end

  defp find_chunk(_, _want), do: {:error, :unsupported}

  defp pcm16_format(
         <<1::little-16, channels::little-16, rate::little-32, _::binary-6, 16::little-16,
           _::binary>>
       )
       when channels > 0 and rate > 0,
       do: {:ok, rate, channels}

  # WAVE_FORMAT_EXTENSIBLE: the subformat GUID starts with the format code.
  defp pcm16_format(
         <<0xFFFE::little-16, channels::little-16, rate::little-32, _::binary-6, 16::little-16,
           _cb::little-16, _valid::little-16, _mask::little-32, 1::little-16, _::binary>>
       )
       when channels > 0 and rate > 0,
       do: {:ok, rate, channels}

  defp pcm16_format(_), do: {:error, :unsupported}
end
