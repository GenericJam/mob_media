defmodule MobMedia.SelfTestTest do
  use ExUnit.Case, async: false

  alias MobMedia.Engine.Fake
  alias MobMedia.SelfTest

  @ctx %{platform: :android, device: :emulator}

  setup do
    dir = Path.join(System.tmp_dir!(), "mob_media_selftest_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:mob_media, :tmp_dir, dir)

    on_exit(fn ->
      Application.delete_env(:mob_media, :engine)
      Application.delete_env(:mob_media, :tmp_dir)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "passes when the engine decodes the tone as the NIF must", %{dir: dir} do
    Application.put_env(:mob_media, :engine, Fake)
    assert SelfTest.run(@ctx, engine: Fake, dir: dir) == :pass
    assert File.ls!(dir) == []
  end

  test "fails, naming the engine, when the NIF isn't linked" do
    assert {:fail, reason} = SelfTest.run(@ctx)
    assert reason =~ "MobMedia.Engine.Unavailable"
  end

  test "fails when the decode is the wrong length", %{dir: dir} do
    Application.put_env(:mob_media, :engine, MobMedia.Test.ShortEngine)

    assert {:fail, reason} = SelfTest.run(@ctx, engine: MobMedia.Test.ShortEngine, dir: dir)
    assert reason =~ "16000 bytes"
  end

  test "the tone is a valid 1 s 44.1 kHz stereo WAV" do
    assert {:ok, %{rate: 44_100, channels: 2, pcm: pcm}} =
             MobMedia.PCM.parse_wav(SelfTest.tone_wav())

    assert MobMedia.PCM.duration_ms(pcm, 44_100, 2) == 1_000
  end
end
