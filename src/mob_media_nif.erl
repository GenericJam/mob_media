%% mob_media_nif — the NIF module behind MobMedia.Engine.Native.
%%
%% iOS: priv/native/ios/mob_media_nif.m (AVFoundation).
%% Android: priv/native/jni/mob_media_nif.c, calling the Kotlin bridge
%% io.mob.media.MobMediaBridge (MediaExtractor, MediaCodec,
%% MediaMetadataRetriever).
%%
%% Every operation returns at once: ok when the work was queued on a native
%% thread, {error, Reason} when it couldn't be. The result arrives later as
%% exactly one message to the calling process:
%%
%%   {mob_media, Ref, {ok, {DurationMs, Width, Height, HasAudio, HasVideo, Mime}}}  info/2
%%   {mob_media, Ref, {ok, Bytes}}                                                   audio_pcm/5
%%   {mob_media, Ref, {ok, {Width, Height}}}                                         frame/6
%%   {mob_media, Ref, {error, Reason}}
%%
%% DurationMs is -1 when unknown, Width/Height 0 without video, Mime <<>> when
%% unknown. Reason: not_found | unsupported | no_audio | no_video |
%% decode_failed | io_error. Synchronous errors on Android add
%% {jni, no_jenv | bridge_not_registered | alloc | call_failed}.
%%
%% Statically linked into the app; on the host (or a native build made before
%% the plugin was activated) nothing is linked. on_load tolerates that so the
%% module still loads: available/0 then answers false (the NIF replaces it
%% with one answering true) and the operations raise nif_not_loaded.
-module(mob_media_nif).
-export([available/0, info/2, audio_pcm/5, frame/6]).
-on_load(init/0).

init() ->
    case erlang:load_nif("mob_media_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

available() -> false.

info(_Ref, _Path) -> erlang:nif_error(nif_not_loaded).

audio_pcm(_Ref, _Path, _Out, _Rate, _Channels) -> erlang:nif_error(nif_not_loaded).

frame(_Ref, _Path, _Out, _AtMs, _MaxPx, _Quality) -> erlang:nif_error(nif_not_loaded).
