defmodule MobMedia.Test.ShortEngine do
  @moduledoc false
  # The fake engine, except that audio_pcm/5 delivers only the first half of
  # the decode: a broken decoder the self-test must catch.
  @behaviour MobMedia.Engine

  alias MobMedia.Engine.Fake

  @impl true
  defdelegate info(ref, path), to: Fake

  @impl true
  def audio_pcm(ref, path, out, rate, channels) do
    caller = self()
    inner = make_ref()
    :ok = Fake.audio_pcm(inner, path, out, rate, channels)

    receive do
      {:mob_media, ^inner, {:ok, bytes}} ->
        half = div(bytes, 4) * 2
        File.write!(out, binary_part(File.read!(out), 0, half))
        send(caller, {:mob_media, ref, {:ok, half}})
    end

    :ok
  end

  @impl true
  defdelegate frame(ref, path, out, at_ms, max_px, quality), to: Fake

  @impl true
  def available?, do: true

  @impl true
  def tmp_dir, do: System.tmp_dir!()
end
