/* mob_media_nif.m (iOS) — MobMedia's NIF over AVFoundation, compiled as
 * Objective-C with -fobjc-arc (manifest lang: :objc).
 *
 * Function surface (the stubs in src/mob_media_nif.erl):
 *   available()                                   -> true
 *   info(Ref, Path)                               -> ok
 *   audio_pcm(Ref, Path, Out, Rate, Channels)     -> ok
 *   frame(Ref, Path, Out, AtMs, MaxPx, Quality)   -> ok
 *
 * Each NIF only queues a block on an NSOperationQueue (at most two run at
 * once) and returns; the block sends exactly one message to the caller:
 *   {mob_media, Ref, {ok, {DurationMs, Width, Height, HasAudio, HasVideo, Mime}}}
 *   {mob_media, Ref, {ok, Bytes}}            (audio_pcm: s16le bytes written to Out)
 *   {mob_media, Ref, {ok, {Width, Height}}}  (frame: JPEG written to Out)
 *   {mob_media, Ref, {error, Reason}}
 * Reason: not_found | unsupported | no_audio | no_video | decode_failed |
 * io_error — the same atoms the Android side sends.
 *
 *   info       AVURLAsset (duration, tracks, the first video track's
 *              naturalSize through its preferredTransform); MIME type from
 *              the file name's extension (UTType)
 *   audio_pcm  AVAssetReader on the first audio track with LinearPCM output
 *              settings at the requested rate and channels (Core Audio
 *              converts), streamed into Out
 *   frame      AVAssetImageGenerator (exact time, preferred transform
 *              applied, maximumSize) + ImageIO JPEG
 *
 * Blocking AVFoundation loads run on the background queue, never on a BEAM
 * scheduler.
 */
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <erl_nif.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    ErlNifEnv *env;
    ErlNifPid pid;
    ERL_NIF_TERM ref;
} mm_job;

/* A failure inside a job: the reason atom it's delivered as. */
typedef const char *mm_reason;

/* ── Delivery ──────────────────────────────────────────────────────────── */

static void mm_send(mm_job *job, ERL_NIF_TERM result) {
    ErlNifEnv *e = job->env;
    ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "mob_media"), job->ref, result);
    enif_send(NULL, &job->pid, e, msg);
    enif_free_env(e);
    enif_free(job);
}

static ERL_NIF_TERM mm_ok(ErlNifEnv *e, ERL_NIF_TERM value) {
    return enif_make_tuple2(e, enif_make_atom(e, "ok"), value);
}

static ERL_NIF_TERM mm_error(ErlNifEnv *e, mm_reason reason) {
    return enif_make_tuple2(e, enif_make_atom(e, "error"), enif_make_atom(e, reason));
}

static ERL_NIF_TERM mm_bool(ErlNifEnv *e, BOOL b) {
    return enif_make_atom(e, b ? "true" : "false");
}

/* ── Loading (blocking; background queue only) ─────────────────────────── */

/* The asset at path, its duration and tracks loaded; nil and *reason set when
 * the file is missing or isn't a format AVFoundation opens. */
static AVURLAsset *mm_asset(NSString *path, mm_reason *reason) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        *reason = "not_found";
        return nil;
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path]
                                            options:@{
                                                AVURLAssetPreferPreciseDurationAndTimingKey : @YES
                                            }];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [asset loadValuesAsynchronouslyForKeys:@[ @"duration", @"tracks" ]
                         completionHandler:^{
                           dispatch_semaphore_signal(done);
                         }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);

    NSError *err = nil;
    if ([asset statusOfValueForKey:@"tracks" error:&err] != AVKeyValueStatusLoaded ||
        [asset statusOfValueForKey:@"duration" error:&err] != AVKeyValueStatusLoaded) {
        *reason = "unsupported";
        return nil;
    }
    return asset;
}

static NSArray<AVAssetTrack *> *mm_tracks(AVAsset *asset, AVMediaType type) {
    __block NSArray<AVAssetTrack *> *tracks = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [asset loadTracksWithMediaType:type
                 completionHandler:^(NSArray<AVAssetTrack *> *loaded, NSError *error) {
                   (void)error;
                   tracks = loaded;
                   dispatch_semaphore_signal(done);
                 }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return tracks ?: @[];
}

/* The size a video track is shown at (naturalSize through preferredTransform). */
static CGSize mm_display_size(AVAssetTrack *track) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [track loadValuesAsynchronouslyForKeys:@[ @"naturalSize", @"preferredTransform" ]
                         completionHandler:^{
                           dispatch_semaphore_signal(done);
                         }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    CGSize s = CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform);
    return CGSizeMake(fabs(s.width), fabs(s.height));
}

static long long mm_duration_ms(AVAsset *asset) {
    CMTime d = asset.duration;
    if (!CMTIME_IS_NUMERIC(d))
        return -1;
    return (long long)llround(CMTimeGetSeconds(d) * 1000.0);
}

/* ── info ──────────────────────────────────────────────────────────────── */

static void mm_info(mm_job *job, NSString *path) {
    ErlNifEnv *e = job->env;
    mm_reason reason = NULL;
    AVURLAsset *asset = mm_asset(path, &reason);
    if (asset == nil) {
        mm_send(job, mm_error(e, reason));
        return;
    }

    NSArray<AVAssetTrack *> *audio = mm_tracks(asset, AVMediaTypeAudio);
    NSArray<AVAssetTrack *> *video = mm_tracks(asset, AVMediaTypeVideo);
    if (audio.count == 0 && video.count == 0) {
        mm_send(job, mm_error(e, "unsupported"));
        return;
    }

    CGSize size = video.count > 0 ? mm_display_size(video.firstObject) : CGSizeZero;
    NSString *ext = path.pathExtension;
    NSString *mime =
        ext.length > 0 ? [UTType typeWithFilenameExtension:ext].preferredMIMEType : nil;
    const char *mime_c = mime ? mime.UTF8String : "";
    size_t mime_len = strlen(mime_c);
    ERL_NIF_TERM mime_term;
    memcpy(enif_make_new_binary(e, mime_len, &mime_term), mime_c, mime_len);

    ERL_NIF_TERM t[6] = {
        enif_make_int64(e, mm_duration_ms(asset)),
        enif_make_int(e, (int)lround(size.width)),
        enif_make_int(e, (int)lround(size.height)),
        mm_bool(e, audio.count > 0),
        mm_bool(e, video.count > 0),
        mime_term,
    };
    mm_send(job, mm_ok(e, enif_make_tuple_from_array(e, t, 6)));
}

/* ── audio_pcm ─────────────────────────────────────────────────────────── */

/* Stream the first audio track of asset to out; bytes written, or -1 with
 * *reason set. */
static long long mm_decode(AVAsset *asset, NSString *out, int rate, int channels,
                           mm_reason *reason) {
    AVAssetTrack *track = mm_tracks(asset, AVMediaTypeAudio).firstObject;
    if (track == nil) {
        *reason = "no_audio";
        return -1;
    }

    NSError *err = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (reader == nil) {
        *reason = "unsupported";
        return -1;
    }
    NSDictionary *settings = @{
        AVFormatIDKey : @(kAudioFormatLinearPCM),
        AVSampleRateKey : @(rate),
        AVNumberOfChannelsKey : @(channels),
        AVLinearPCMBitDepthKey : @16,
        AVLinearPCMIsFloatKey : @NO,
        AVLinearPCMIsBigEndianKey : @NO,
        AVLinearPCMIsNonInterleaved : @NO,
    };
    AVAssetReaderTrackOutput *output =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) {
        *reason = "unsupported";
        return -1;
    }
    [reader addOutput:output];
    if (![reader startReading]) {
        *reason = "unsupported";
        return -1;
    }

    FILE *f = fopen(out.fileSystemRepresentation, "wb");
    if (f == NULL) {
        [reader cancelReading];
        *reason = "io_error";
        return -1;
    }

    long long bytes = 0;
    size_t cap = 0;
    char *buf = NULL;
    BOOL ok = YES;
    while (ok) {
        @autoreleasepool {
            CMSampleBufferRef sample = [output copyNextSampleBuffer];
            if (sample == NULL)
                break;
            CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
            size_t len = block ? CMBlockBufferGetDataLength(block) : 0;
            if (len > cap) {
                char *grown = realloc(buf, len);
                if (grown == NULL) {
                    ok = NO;
                    *reason = "decode_failed";
                } else {
                    buf = grown;
                    cap = len;
                }
            }
            if (ok && len > 0) {
                if (CMBlockBufferCopyDataBytes(block, 0, len, buf) != kCMBlockBufferNoErr) {
                    ok = NO;
                    *reason = "decode_failed";
                } else if (fwrite(buf, 1, len, f) != len) {
                    ok = NO;
                    *reason = "io_error";
                } else {
                    bytes += (long long)len;
                }
            }
            CFRelease(sample);
        }
    }
    free(buf);

    if (!ok)
        [reader cancelReading];
    else if (reader.status != AVAssetReaderStatusCompleted) {
        ok = NO;
        *reason = "decode_failed";
    }
    if (fclose(f) != 0 && ok) {
        ok = NO;
        *reason = "io_error";
    }
    return ok ? bytes : -1;
}

static void mm_audio_pcm(mm_job *job, NSString *path, NSString *out, int rate, int channels) {
    ErlNifEnv *e = job->env;
    mm_reason reason = NULL;
    AVURLAsset *asset = mm_asset(path, &reason);
    long long bytes = asset ? mm_decode(asset, out, rate, channels, &reason) : -1;
    mm_send(job, bytes >= 0 ? mm_ok(e, enif_make_int64(e, bytes)) : mm_error(e, reason));
}

/* ── frame ─────────────────────────────────────────────────────────────── */

static CGImageRef mm_generate(AVAssetImageGenerator *gen, CMTime t) {
    __block CGImageRef image = NULL;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [gen generateCGImageAsynchronouslyForTime:t
                            completionHandler:^(CGImageRef img, CMTime actual, NSError *error) {
                              (void)actual;
                              (void)error;
                              if (img)
                                  image = CGImageRetain(img);
                              dispatch_semaphore_signal(done);
                            }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return image;
}

static BOOL mm_write_jpeg(CGImageRef image, NSString *out, int quality) {
    CGImageDestinationRef dest =
        CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:out],
                                        (__bridge CFStringRef)UTTypeJPEG.identifier, 1, NULL);
    if (dest == NULL)
        return NO;
    NSDictionary *props =
        @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @(quality / 100.0)};
    CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)props);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return ok;
}

static void mm_frame(mm_job *job, NSString *path, NSString *out, long long at_ms, int max_px,
                     int quality) {
    ErlNifEnv *e = job->env;
    mm_reason reason = NULL;
    AVURLAsset *asset = mm_asset(path, &reason);
    if (asset == nil) {
        mm_send(job, mm_error(e, reason));
        return;
    }
    if (mm_tracks(asset, AVMediaTypeVideo).count == 0) {
        mm_send(job, mm_error(e, "no_video"));
        return;
    }

    long long duration = mm_duration_ms(asset);
    if (duration >= 0 && at_ms > duration)
        at_ms = duration;
    CMTime t = CMTimeMake(at_ms, 1000);

    AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    gen.appliesPreferredTrackTransform = YES;
    if (max_px > 0)
        gen.maximumSize = CGSizeMake(max_px, max_px);
    gen.requestedTimeToleranceBefore = kCMTimeZero;
    gen.requestedTimeToleranceAfter = kCMTimeZero;

    CGImageRef image = mm_generate(gen, t);
    if (image == NULL) {
        /* At or past the last frame an exact request can fail; take the
         * nearest earlier one. */
        gen.requestedTimeToleranceBefore = kCMTimePositiveInfinity;
        image = mm_generate(gen, t);
    }
    if (image == NULL) {
        mm_send(job, mm_error(e, "decode_failed"));
        return;
    }

    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    BOOL written = mm_write_jpeg(image, out, quality);
    CGImageRelease(image);
    mm_send(job, written ? mm_ok(e, enif_make_tuple2(e, enif_make_int(e, (int)w),
                                                     enif_make_int(e, (int)h)))
                         : mm_error(e, "io_error"));
}

/* ── NIFs (called on a BEAM scheduler; they only queue the job) ────────── */

/* At most two jobs at once, and queued jobs wait in the operation queue,
 * not on a blocked GCD worker thread each. */
static void mm_queue(void (^work)(void)) {
    static NSOperationQueue *queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      queue = [[NSOperationQueue alloc] init];
      queue.name = @"mob_media";
      queue.maxConcurrentOperationCount = 2;
      queue.qualityOfService = NSQualityOfServiceUtility;
    });
    [queue addOperationWithBlock:^{
      @autoreleasepool {
          work();
      }
    }];
}

static mm_job *mm_job_new(ErlNifEnv *env, ERL_NIF_TERM ref) {
    mm_job *job = enif_alloc(sizeof(mm_job));
    if (job == NULL)
        return NULL;
    job->env = enif_alloc_env();
    if (job->env == NULL) {
        enif_free(job);
        return NULL;
    }
    job->ref = enif_make_copy(job->env, ref);
    enif_self(env, &job->pid);
    return job;
}

/* A path as an NSString; nil for an empty path, one with a NUL, or invalid
 * UTF-8. */
static NSString *mm_path(ErlNifEnv *env, ERL_NIF_TERM term) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, term, &bin) || bin.size == 0 ||
        memchr(bin.data, 0, bin.size) != NULL)
        return nil;
    return [[NSString alloc] initWithBytes:bin.data length:bin.size encoding:NSUTF8StringEncoding];
}

static ERL_NIF_TERM mm_alloc_error(ErlNifEnv *env) {
    return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "alloc"));
}

static ERL_NIF_TERM mm_available(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    return enif_make_atom(env, "true");
}

static ERL_NIF_TERM mm_info_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NSString *path = mm_path(env, argv[1]);
    if (!enif_is_ref(env, argv[0]) || path == nil)
        return enif_make_badarg(env);
    mm_job *job = mm_job_new(env, argv[0]);
    if (job == NULL)
        return mm_alloc_error(env);
    mm_queue(^{
      mm_info(job, path);
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM mm_audio_pcm_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NSString *path = mm_path(env, argv[1]);
    NSString *out = mm_path(env, argv[2]);
    int rate, channels;
    if (!enif_is_ref(env, argv[0]) || path == nil || out == nil ||
        !enif_get_int(env, argv[3], &rate) || !enif_get_int(env, argv[4], &channels) || rate <= 0 ||
        channels < 1 || channels > 2)
        return enif_make_badarg(env);
    mm_job *job = mm_job_new(env, argv[0]);
    if (job == NULL)
        return mm_alloc_error(env);
    mm_queue(^{
      mm_audio_pcm(job, path, out, rate, channels);
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM mm_frame_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NSString *path = mm_path(env, argv[1]);
    NSString *out = mm_path(env, argv[2]);
    ErlNifSInt64 at_ms;
    int max_px, quality;
    if (!enif_is_ref(env, argv[0]) || path == nil || out == nil ||
        !enif_get_int64(env, argv[3], &at_ms) || !enif_get_int(env, argv[4], &max_px) ||
        !enif_get_int(env, argv[5], &quality) || at_ms < 0 || max_px < 0 || quality < 1 ||
        quality > 100)
        return enif_make_badarg(env);
    mm_job *job = mm_job_new(env, argv[0]);
    if (job == NULL)
        return mm_alloc_error(env);
    mm_queue(^{
      mm_frame(job, path, out, (long long)at_ms, max_px, quality);
    });
    return enif_make_atom(env, "ok");
}

static ErlNifFunc nif_funcs[] = {
    {"available", 0, mm_available, 0},
    {"info", 2, mm_info_nif, 0},
    {"audio_pcm", 5, mm_audio_pcm_nif, 0},
    {"frame", 6, mm_frame_nif, 0},
};

ERL_NIF_INIT(mob_media_nif, nif_funcs, NULL, NULL, NULL, NULL)
