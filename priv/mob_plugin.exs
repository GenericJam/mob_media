%{
  name: :mob_media,
  mob_version: "~> 0.9",
  plugin_spec_version: 1,
  description:
    "Media info, audio to PCM and video frames as JPEG " <>
      "(Android MediaExtractor/MediaCodec/MediaMetadataRetriever; iOS AVAssetReader/AVAssetImageGenerator)",
  # On-device proof for `mix mob.selftest` / mob_ci: a WAV the test writes is
  # probed and decoded to 16 kHz mono through the NIF, and frame/3 on it must
  # answer :no_video (see Mob.Plugin.SelfTest).
  selftest: MobMedia.SelfTest,
  # A sample screen the host can navigate to by route: pick a file, see its
  # info, decode its audio, grab a frame. Drop it (and this entry) in a real
  # app.
  screens: [
    %{module: MobMedia.DemoScreen, default_route: "/mob_media/demo"}
  ],
  nifs: [
    # iOS: Objective-C over AVFoundation (AVURLAsset, AVAssetReader,
    # AVAssetImageGenerator) and ImageIO for the JPEG. lang: :objc compiles it
    # with -fobjc-arc; platform: :ios keeps it out of the Android build.
    %{module: :mob_media_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios},
    # Android: C JNI handing each job to io.mob.media.MobMediaBridge
    # (priv/native/android), which decodes on its own threads.
    %{module: :mob_media_nif, native_dir: "priv/native/jni", lang: :c, platform: :android}
  ],
  # No runtime permission: every operation reads a local file the app can
  # already read (picked, captured or recorded by the app). Getting such a
  # path is the job of Mob.Files, mob_photos or mob_camera.
  android: %{
    bridge_kt: "priv/native/android/MobMediaBridge.kt",
    bridge_class: "io.mob.media.MobMediaBridge",
    # MediaExtractor, MediaCodec and MediaMetadataRetriever are framework
    # classes: no Gradle dependency, no permission.
    permissions: []
  },
  ios: %{
    frameworks: ["AVFoundation", "CoreMedia", "CoreGraphics", "ImageIO", "UniformTypeIdentifiers"]
  }
}
