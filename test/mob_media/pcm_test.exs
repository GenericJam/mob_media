defmodule MobMedia.PCMTest do
  use ExUnit.Case, async: true

  alias MobMedia.PCM

  defp pcm(samples), do: for(s <- samples, into: <<>>, do: <<s::little-signed-16>>)
  defp samples(pcm), do: for(<<s::little-signed-16 <- pcm>>, do: s)

  describe "convert/5 channels" do
    test "same rate and channels is the identity" do
      input = pcm([1, -2, 3, -4, 32_767, -32_768])
      assert PCM.convert(input, 16_000, 2, 16_000, 2) == input
    end

    test "to mono averages every channel, truncating toward zero" do
      assert samples(PCM.convert(pcm([3, 0, -3, 0, 10, 11]), 8_000, 2, 8_000, 1)) == [1, -1, 10]
      assert samples(PCM.convert(pcm([1, 2, 3, 4, 5, 6]), 8_000, 6, 8_000, 1)) == [3]
    end

    test "mono to stereo duplicates; more than two to stereo keeps the first two" do
      assert samples(PCM.convert(pcm([5, -6]), 8_000, 1, 8_000, 2)) == [5, 5, -6, -6]
      assert samples(PCM.convert(pcm([1, 2, 3, 4, 5, 6]), 8_000, 3, 8_000, 2)) == [1, 2, 4, 5]
    end

    test "a trailing partial frame is dropped" do
      assert samples(PCM.convert(pcm([1, 2, 3]), 8_000, 2, 8_000, 2)) == [1, 2]
      assert PCM.convert(<<1, 2, 3>>, 8_000, 1, 8_000, 1) == <<1, 2>>
    end

    test "empty input gives empty output" do
      assert PCM.convert(<<>>, 44_100, 2, 16_000, 1) == <<>>
    end
  end

  describe "convert/5 downsampling" do
    test "averages each box of input frames" do
      # 3:1 — boxes [0,3) [3,6); the 7th frame never completes a box.
      input = pcm([3, 6, 9, -1, -2, -3, 100])
      assert samples(PCM.convert(input, 48_000, 1, 16_000, 1)) == [6, -2]
    end

    test "uneven boxes follow floor(k * in / out)" do
      # 44.1 kHz -> 16 kHz: box edges 0, 2, 5, 8, 11.
      input = pcm(Enum.to_list(0..10))
      assert samples(PCM.convert(input, 44_100, 1, 16_000, 1)) == [0, 3, 6, 9]
    end

    test "averages per channel after mapping" do
      input = pcm([2, 4, 6, 8, 10, 12, 14, 16])
      assert samples(PCM.convert(input, 32_000, 2, 16_000, 2)) == [4, 6, 12, 14]
    end
  end

  describe "convert/5 upsampling" do
    test "interpolates linearly, rounding half up, and repeats the last frame" do
      # 1:2 — positions 0, 0.5, 1, 1.5
      assert samples(PCM.convert(pcm([0, 3]), 8_000, 1, 16_000, 1)) == [0, 2, 3, 3]
      assert samples(PCM.convert(pcm([0, -3]), 8_000, 1, 16_000, 1)) == [0, -1, -3, -3]
    end

    test "non-integer ratios place outputs at k * in / out" do
      # 2:3 — positions 0, 2/3, 4/3, 2, 8/3
      input = pcm([0, 30, 60])
      assert samples(PCM.convert(input, 16_000, 1, 24_000, 1)) == [0, 20, 40, 60, 60]
    end
  end

  test "output length is within a frame of n * out / in" do
    for {in_rate, out_rate} <- [{44_100, 16_000}, {48_000, 16_000}, {22_050, 16_000}],
        n <- [1, 2, 99, 1_000] do
      out = PCM.convert(pcm(List.duplicate(7, n)), in_rate, 1, out_rate, 1)
      assert_in_delta byte_size(out) / 2, n * out_rate / in_rate, 1
    end
  end

  test "duration_ms/3 counts frames at the rate" do
    assert PCM.duration_ms(:binary.copy(<<0, 0>>, 16_000), 16_000, 1) == 1_000
    assert PCM.duration_ms(:binary.copy(<<0, 0>>, 44_100), 44_100, 2) == 500
  end

  describe "wav/3 and parse_wav/1" do
    test "round-trip" do
      data = pcm([1, -1, 2, -2])

      assert PCM.parse_wav(PCM.wav(data, 22_050, 2)) ==
               {:ok, %{rate: 22_050, channels: 2, pcm: data}}
    end

    test "skip unknown chunks, including odd-sized padded ones" do
      fmt =
        <<1::little-16, 1::little-16, 8_000::little-32, 16_000::little-32, 2::little-16,
          16::little-16>>

      body =
        "WAVE" <>
          "LIST" <>
          <<3::little-32>> <>
          "abc" <>
          <<0>> <>
          "fmt " <> <<16::little-32>> <> fmt <> "data" <> <<4::little-32>> <> pcm([9, -9])

      wav = "RIFF" <> <<byte_size(body)::little-32>> <> body
      assert PCM.parse_wav(wav) == {:ok, %{rate: 8_000, channels: 1, pcm: pcm([9, -9])}}
    end

    test "WAVE_FORMAT_EXTENSIBLE with the PCM subformat" do
      fmt =
        <<0xFFFE::little-16, 6::little-16, 48_000::little-32, 576_000::little-32, 12::little-16,
          16::little-16, 22::little-16, 16::little-16, 63::little-32, 1::little-16,
          0::size(14)-unit(8)>>

      body = "WAVE" <> "fmt " <> <<40::little-32>> <> fmt <> "data" <> <<0::little-32>>
      wav = "RIFF" <> <<byte_size(body)::little-32>> <> body
      assert {:ok, %{rate: 48_000, channels: 6}} = PCM.parse_wav(wav)
    end

    test "a truncated data chunk keeps whole frames" do
      wav = PCM.wav(pcm([1, 2, 3, 4]), 8_000, 2)
      truncated = binary_part(wav, 0, byte_size(wav) - 3)
      assert PCM.parse_wav(truncated) == {:ok, %{rate: 8_000, channels: 2, pcm: pcm([1, 2])}}
    end

    test "anything but 16-bit PCM is unsupported" do
      float =
        PCM.wav(<<0::32>>, 8_000, 1)
        |> String.replace(<<1::little-16, 1::little-16>>, <<3::little-16, 1::little-16>>,
          global: false
        )

      eight_bit =
        PCM.wav(<<0, 0>>, 8_000, 1)
        |> String.replace(<<16::little-16, "data">>, <<8::little-16, "data">>)

      for wav <- [float, eight_bit, "RIFF", "not a wav", <<>>] do
        assert PCM.parse_wav(wav) == {:error, :unsupported}
      end
    end
  end
end
