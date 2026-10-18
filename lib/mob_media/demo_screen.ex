defmodule MobMedia.DemoScreen do
  @moduledoc """
  A ready-to-run sample screen exercising `MobMedia`, shipped so a generated
  app can try the plugin the moment it's activated. Declared in the plugin
  manifest's `:screens` (route `/mob_media/demo`). Delete it (and the
  manifest entry) in a real app.

  **Pick a file** opens the system picker for audio or video; **Sample tone**
  writes a one-second WAV. Either way the screen shows the file's info, the
  length of its audio decoded to 16 kHz mono PCM (beside the duration, so a
  mismatch is visible), and for a video the frame at one second.

  The work runs in a task: `MobMedia`'s functions block their caller until the
  answer is ready, and a screen that blocks stops answering taps.
  """
  use Mob.Screen

  alias MobMedia.PCM

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       status: if(MobMedia.available?(), do: "Pick a file.", else: "mob_media NIF not linked"),
       info: nil,
       audio: nil,
       frame: nil,
       frame_path: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background} padding={:space_lg}>
        <Text text="Media" text_size={:lg} text_color={:on_surface} padding={:space_sm} />
        <Text text={assigns.status} text_size={:sm} text_color={:primary} padding={4} />
        <Spacer size={8} />
        <Text text={"info: #{inspect(assigns.info, pretty: true)}"} text_size={:sm} text_color={:on_surface} padding={4} />
        <Text text={"audio: #{assigns.audio || "-"}"} text_size={:sm} text_color={:on_surface} padding={4} />
        <Text text={"frame: #{assigns.frame || "-"}"} text_size={:sm} text_color={:on_surface} padding={4} />
        {frame_image(assigns)}
        <Spacer size={16} />
        <Button text="Pick a file" background={:primary} text_color={:on_primary} padding={:space_md} fill_width={true} on_tap={{self(), :pick}} />
        <Spacer size={12} />
        <Button text="Sample tone" background={:surface} text_color={:on_surface} padding={:space_md} fill_width={true} on_tap={{self(), :tone}} />
      </Column>
    </Scroll>
    """
  end

  defp frame_image(%{frame_path: nil}), do: nil

  defp frame_image(assigns) do
    ~MOB"""
    <Image src={assigns.frame_path} width={240} height={240} content_mode="fit" />
    """
  end

  @impl true
  def handle_info({:tap, :pick}, socket),
    do: {:noreply, Mob.Files.pick(socket, types: [:audio, :video])}

  def handle_info({:tap, :tone}, socket) do
    path = Path.join(Mob.data_dir("mob_media_demo"), "tone.wav")
    File.write!(path, MobMedia.SelfTest.tone_wav())
    {:noreply, examine(socket, path)}
  end

  def handle_info({:files, :picked, [%{path: path} | _]}, socket),
    do: {:noreply, examine(socket, path)}

  def handle_info({:files, :cancelled}, socket), do: {:noreply, socket}

  def handle_info({:mob_media_demo, results}, socket),
    do: {:noreply, Mob.Socket.assign(socket, results)}

  def handle_info(_other, socket), do: {:noreply, socket}

  defp examine(socket, path) do
    screen = self()
    Task.start(fn -> send(screen, {:mob_media_demo, results(path)}) end)

    Mob.Socket.assign(socket,
      status: "Working on #{Path.basename(path)}…",
      info: nil,
      audio: nil,
      frame: nil,
      frame_path: nil
    )
  end

  defp results(path) do
    {us, info} = :timer.tc(fn -> MobMedia.info(path) end)
    {pcm_us, pcm} = :timer.tc(fn -> MobMedia.audio_pcm(path) end)
    {frame_text, frame_path} = frame(info, path)

    [
      status: "Done: #{Path.basename(path)} (info #{div(us, 1000)} ms)",
      info: info,
      audio: audio_text(pcm, pcm_us),
      frame: frame_text,
      frame_path: frame_path
    ]
  end

  defp audio_text({:ok, pcm}, us),
    do:
      "#{byte_size(pcm)} bytes = #{PCM.duration_ms(pcm, 16_000, 1)} ms of 16 kHz mono " <>
        "(decoded in #{div(us, 1000)} ms)"

  defp audio_text(error, _us), do: inspect(error)

  defp frame({:ok, %{has_video: true}}, path) do
    case MobMedia.frame(path, 1_000, max_px: 480) do
      {:ok, jpeg} ->
        # A new name each time: the image view caches by path.
        name = "frame_#{System.unique_integer([:positive])}.jpg"
        out = Path.join(Mob.data_dir("mob_media_demo"), name)
        File.write!(out, jpeg)
        {"#{byte_size(jpeg)} bytes of JPEG at 1 s", out}

      error ->
        {inspect(error), nil}
    end
  end

  defp frame(_info, _path), do: {"no video", nil}
end
