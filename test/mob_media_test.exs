defmodule MobMediaTest do
  # async: false: the engine and tmp_dir are app-wide config, scripts global.
  use ExUnit.Case, async: false

  alias MobMedia.Engine.Fake
  alias MobMedia.PCM

  setup do
    dir = Path.join(System.tmp_dir!(), "mob_media_test_#{System.unique_integer([:positive])}")
    tmp = Path.join(dir, "tmp")
    File.mkdir_p!(tmp)
    Application.put_env(:mob_media, :engine, Fake)
    Application.put_env(:mob_media, :tmp_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:mob_media, :engine)
      Application.delete_env(:mob_media, :tmp_dir)
      Fake.reset()
      File.rm_rf!(dir)
    end)

    %{dir: dir, tmp: tmp}
  end

  # A 44.1 kHz stereo ramp, 500 ms.
  defp stereo_pcm do
    for i <- 0..(22_050 - 1),
        into: <<>>,
        do: <<rem(i, 1000)::little-signed-16, -i::little-signed-16>>
  end

  defp write_wav(dir, name \\ "a.wav") do
    path = Path.join(dir, name)
    File.write!(path, PCM.wav(stereo_pcm(), 44_100, 2))
    path
  end

  defp touch(dir, name) do
    path = Path.join(dir, name)
    File.write!(path, "not really media")
    path
  end

  describe "a WAV through the fake engine" do
    test "info/1 reports the audio and no video", %{dir: dir} do
      assert MobMedia.info(write_wav(dir)) ==
               {:ok,
                %{
                  duration_ms: 500,
                  width: nil,
                  height: nil,
                  has_audio: true,
                  has_video: false,
                  mime: "audio/wav"
                }}
    end

    test "audio_pcm/2 defaults to 16 kHz mono, converted as MobMedia.PCM does", %{dir: dir} do
      assert {:ok, pcm} = MobMedia.audio_pcm(write_wav(dir))
      assert pcm == PCM.convert(stereo_pcm(), 44_100, 2, 16_000, 1)
      assert PCM.duration_ms(pcm, 16_000, 1) == 500
    end

    test "audio_pcm/2 honours :rate and :channels", %{dir: dir} do
      assert {:ok, pcm} = MobMedia.audio_pcm(write_wav(dir), rate: 8_000, channels: 2)
      assert pcm == PCM.convert(stereo_pcm(), 44_100, 2, 8_000, 2)
    end

    test "frame/3 is :no_video", %{dir: dir} do
      assert MobMedia.frame(write_wav(dir), 0) == {:error, :no_video}
    end

    test "temporary output files are gone afterwards", %{dir: dir, tmp: tmp} do
      path = write_wav(dir)
      {:ok, _} = MobMedia.audio_pcm(path)
      {:error, :no_video} = MobMedia.frame(path, 0)
      assert File.ls!(tmp) == []
    end
  end

  describe "audio_pcm/2 with :to" do
    test "leaves the PCM in that file and returns its path", %{dir: dir} do
      to = Path.join(dir, "out.pcm")
      assert MobMedia.audio_pcm(write_wav(dir), to: to) == {:ok, to}
      assert File.read!(to) == PCM.convert(stereo_pcm(), 44_100, 2, 16_000, 1)
      assert Path.wildcard(Path.join(dir, "*.part")) == []
    end

    test "writes nothing at `to` when the decode fails", %{dir: dir} do
      path = touch(dir, "v.mp4")
      Fake.script(path, audio: {:error, :decode_failed})
      to = Path.join(dir, "out.pcm")

      assert MobMedia.audio_pcm(path, to: to) == {:error, :decode_failed}
      assert File.ls!(dir) |> Enum.sort() == ["tmp", "v.mp4"]
    end

    test "an unwritable `to` is :io_error", %{dir: dir} do
      to = Path.join([dir, "no_such_dir", "out.pcm"])
      assert MobMedia.audio_pcm(write_wav(dir), to: to) == {:error, :io_error}
    end
  end

  describe "scripted media" do
    test "info/1 maps the native tuple: unknowns to nil, MIME aliases folded", %{dir: dir} do
      video = touch(dir, "v.mp4")

      Fake.script(video,
        info: %{
          duration_ms: 12_480,
          width: 1080,
          height: 1920,
          has_audio: true,
          has_video: true,
          mime: "video/mp4"
        }
      )

      audio = touch(dir, "a.m4a")
      Fake.script(audio, info: %{has_audio: true, mime: "audio/x-m4a", width: 640})

      assert MobMedia.info(video) ==
               {:ok,
                %{
                  duration_ms: 12_480,
                  width: 1080,
                  height: 1920,
                  has_audio: true,
                  has_video: true,
                  mime: "video/mp4"
                }}

      assert MobMedia.info(audio) ==
               {:ok,
                %{
                  duration_ms: nil,
                  width: nil,
                  height: nil,
                  has_audio: true,
                  has_video: false,
                  mime: "audio/mp4"
                }}
    end

    test "a video's audio track converts to the requested format", %{dir: dir} do
      path = touch(dir, "v.mp4")
      Fake.script(path, audio: {stereo_pcm(), 44_100, 2})

      assert MobMedia.audio_pcm(path, channels: 2) ==
               {:ok, PCM.convert(stereo_pcm(), 44_100, 2, 16_000, 2)}
    end

    test "frame/3 returns the JPEG bytes", %{dir: dir, tmp: tmp} do
      path = touch(dir, "v.mp4")
      jpeg = <<0xFF, 0xD8, 0xFF, 0xE0, "fake", 0xFF, 0xD9>>
      Fake.script(path, frame: {jpeg, 640, 360})

      assert MobMedia.frame(path, 1_000, max_px: 640, quality: 90) == {:ok, jpeg}
      assert File.ls!(tmp) == []
    end

    test "errors pass through", %{dir: dir} do
      path = touch(dir, "v.mp4")
      Fake.script(path, info: {:error, :unsupported}, frame: {:error, :decode_failed})

      assert MobMedia.info(path) == {:error, :unsupported}
      assert MobMedia.audio_pcm(path) == {:error, :no_audio}
      assert MobMedia.frame(path, 0) == {:error, :decode_failed}
    end

    test "an unscripted file the fake can't read is :unsupported", %{dir: dir} do
      path = touch(dir, "v.mp4")
      assert MobMedia.info(path) == {:error, :unsupported}
      assert MobMedia.audio_pcm(path) == {:error, :unsupported}
    end
  end

  test "a missing file is :not_found", %{dir: dir} do
    missing = Path.join(dir, "missing.mp4")
    assert MobMedia.info(missing) == {:error, :not_found}
    assert MobMedia.audio_pcm(missing) == {:error, :not_found}
    assert MobMedia.frame(missing, 0) == {:error, :not_found}
  end

  describe "timeouts" do
    test "return :timeout at once and delete the late output", %{dir: dir, tmp: tmp} do
      path = touch(dir, "slow.mp4")
      Fake.script(path, audio: {stereo_pcm(), 44_100, 2}, delay: 200)

      {elapsed, result} = :timer.tc(fn -> MobMedia.audio_pcm(path, timeout: 20) end)
      assert result == {:error, :timeout}
      assert elapsed < 150_000

      Process.sleep(400)
      assert File.ls!(tmp) == []
      refute_received {:mob_media, _, _}
    end

    test "with :to, a late result never appears at `to`", %{dir: dir} do
      path = touch(dir, "slow.mp4")
      Fake.script(path, audio: {stereo_pcm(), 44_100, 2}, delay: 200)
      to = Path.join(dir, "out.pcm")

      assert MobMedia.audio_pcm(path, to: to, timeout: 20) == {:error, :timeout}
      Process.sleep(400)
      assert File.ls!(dir) |> Enum.sort() == ["slow.mp4", "tmp"]
    end

    test "a caller that dies leaves no output behind", %{dir: dir, tmp: tmp} do
      path = touch(dir, "slow.mp4")
      Fake.script(path, audio: {stereo_pcm(), 44_100, 2}, delay: 200)

      {pid, ref} = spawn_monitor(fn -> MobMedia.audio_pcm(path) end)
      Process.sleep(50)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      Process.sleep(400)
      assert File.ls!(tmp) == []
    end
  end

  describe "engines" do
    test "without the NIF or configuration the engine is Unavailable" do
      Application.delete_env(:mob_media, :engine)
      assert MobMedia.engine() == MobMedia.Engine.Unavailable
      refute MobMedia.available?()
    end

    test "Unavailable answers :unavailable without touching the file", %{dir: dir, tmp: tmp} do
      Application.put_env(:mob_media, :engine, MobMedia.Engine.Unavailable)
      path = write_wav(dir)

      assert MobMedia.info(path) == {:error, :unavailable}
      assert MobMedia.audio_pcm(path) == {:error, :unavailable}
      assert MobMedia.frame(path, 0) == {:error, :unavailable}
      assert File.ls!(tmp) == []
    end

    test "a synchronous engine error is returned and its output path cleaned", %{
      dir: dir,
      tmp: tmp
    } do
      Application.put_env(:mob_media, :engine, MobMedia.Test.RefusingEngine)
      path = write_wav(dir)

      assert MobMedia.audio_pcm(path) == {:error, {:jni, :bridge_not_registered}}
      assert File.ls!(tmp) == []
    end

    # Guards the .erl stub (VacuousTest can't see Erlang modules as app code).
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the NIF isn't linked on the host" do
      refute :mob_media_nif.available()
      assert_raise ErlangError, fn -> :mob_media_nif.info(make_ref(), "/x") end
    end
  end

  describe "argument checks" do
    test "bad options raise", %{dir: dir} do
      path = write_wav(dir)

      for opts <- [[rate: 0], [rate: "16000"], [channels: 3], [to: ""], [timeout: -1]] do
        assert_raise ArgumentError, fn -> MobMedia.audio_pcm(path, opts) end
      end

      for opts <- [[max_px: 0], [quality: 0], [quality: 101], [timeout: :never]] do
        assert_raise ArgumentError, fn -> MobMedia.frame(path, 0, opts) end
      end
    end

    test "a negative time doesn't match", %{dir: dir} do
      assert_raise FunctionClauseError, fn -> MobMedia.frame(write_wav(dir), -1) end
    end
  end
end
