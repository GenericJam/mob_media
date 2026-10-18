defmodule MobMedia.Test.RefusingEngine do
  @moduledoc false
  # An engine whose every call fails synchronously, as the Android NIF does
  # when the Kotlin bridge never registered. It writes its output file first,
  # to prove MobMedia cleans up after a refusal.
  @behaviour MobMedia.Engine

  @impl true
  def info(_ref, _path), do: {:error, {:jni, :bridge_not_registered}}

  @impl true
  def audio_pcm(_ref, _path, out, _rate, _channels), do: refuse(out)

  @impl true
  def frame(_ref, _path, out, _at_ms, _max_px, _quality), do: refuse(out)

  @impl true
  def available?, do: true

  @impl true
  def tmp_dir, do: System.tmp_dir!()

  defp refuse(out) do
    File.write!(out, "partial")
    {:error, {:jni, :bridge_not_registered}}
  end
end
