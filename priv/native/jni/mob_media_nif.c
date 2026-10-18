/*
 * mob_media_nif.c (Android) — MobMedia's NIF. Each operation is handed to the
 * Kotlin bridge io.mob.media.MobMediaBridge (priv/native/android), which runs
 * it on its own thread pool (MediaExtractor, MediaCodec,
 * MediaMetadataRetriever) and calls back one nativeDeliver* thunk below with
 * the result. No decoding runs on a BEAM scheduler.
 *
 * Function surface (the stubs in src/mob_media_nif.erl):
 *   available()                                   -> true
 *   info(Ref, Path)                               -> ok | {error, {jni, R}}
 *   audio_pcm(Ref, Path, Out, Rate, Channels)     -> ok | {error, {jni, R}}
 *   frame(Ref, Path, Out, AtMs, MaxPx, Quality)   -> ok | {error, {jni, R}}
 *
 * After ok, exactly one message reaches the calling process:
 *   {mob_media, Ref, {ok, {DurationMs, Width, Height, HasAudio, HasVideo, Mime}}}
 *   {mob_media, Ref, {ok, Bytes}}            (audio_pcm: s16le bytes written to Out)
 *   {mob_media, Ref, {ok, {Width, Height}}}  (frame: JPEG written to Out)
 *   {mob_media, Ref, {error, Reason}}
 * Reason is one of the atoms in mm_reasons, chosen by the bridge's numeric
 * code (MobMediaBridge.E_*): the two lists must stay in the same order.
 *
 * Synchronous {jni, R}: no_jenv | bridge_not_registered | alloc | call_failed
 * (the bridge threw before queueing the job; it logs why under MobMedia).
 *
 * Ownership: a job (caller pid + a copy of Ref in its own env) is malloc'd
 * here and its address crosses JNI as a jlong. Once the bridge's start method
 * returns normally the bridge owns it and delivers exactly once, which frees
 * it; if the start method throws, nothing was queued and it's freed here.
 *
 * The bridge class and method IDs are cached by nativeRegister, which the
 * generated MobPluginBootstrap.registerAll calls (through register()) from
 * MainActivity.onCreate, before the BEAM starts: FindClass from a BEAM thread
 * would search the system class loader and miss the app's classes.
 */

#include <erl_nif.h>
#include <jni.h>
#include <stdint.h>
#include <string.h>

/* mob core exports, linked into the same .so. */
extern JNIEnv *get_jenv(int *attached);
extern JavaVM *g_jvm;

static jclass g_cls = NULL;
static jmethodID g_info = NULL;
static jmethodID g_audio_pcm = NULL;
static jmethodID g_frame = NULL;

/* Index = MobMediaBridge.E_* code. */
static const char *mm_reasons[] = {
    "decode_failed", /* 0: unknown code, never sent on purpose */
    "not_found",     /* 1 */
    "unsupported",   /* 2 */
    "no_audio",      /* 3 */
    "no_video",      /* 4 */
    "decode_failed", /* 5 */
    "io_error",      /* 6 */
};

typedef struct {
    ErlNifEnv *env;
    ErlNifPid pid;
    ERL_NIF_TERM ref;
} mm_job;

/* A static method ID, or NULL with the NoSuchMethodError cleared. */
static jmethodID mm_method(JNIEnv *jenv, jclass cls, const char *name, const char *sig) {
    jmethodID id = (*jenv)->GetStaticMethodID(jenv, cls, name, sig);
    if ((*jenv)->ExceptionCheck(jenv)) {
        (*jenv)->ExceptionClear(jenv);
        return NULL;
    }
    return id;
}

JNIEXPORT void JNICALL Java_io_mob_media_MobMediaBridge_nativeRegister(JNIEnv *jenv, jclass cls) {
    if (g_cls != NULL)
        return;

    jmethodID info = mm_method(jenv, cls, "info", "(J[B)V");
    jmethodID pcm = info ? mm_method(jenv, cls, "audioPcm", "(J[B[BII)V") : NULL;
    jmethodID frame = pcm ? mm_method(jenv, cls, "frame", "(J[B[BJII)V") : NULL;
    if (frame == NULL)
        return;

    /* The method IDs are set before g_cls, which is what callers check. */
    g_info = info;
    g_audio_pcm = pcm;
    g_frame = frame;
    g_cls = (jclass)(*jenv)->NewGlobalRef(jenv, cls);
}

/* ── Delivery (called on the bridge's threads) ─────────────────────────── */

static void mm_deliver(jlong handle, ERL_NIF_TERM (*build)(ErlNifEnv *, void *), void *arg) {
    mm_job *job = (mm_job *)(intptr_t)handle;
    if (job == NULL)
        return;
    ErlNifEnv *e = job->env;
    ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "mob_media"), job->ref, build(e, arg));
    enif_send(NULL, &job->pid, e, msg);
    enif_free_env(e);
    enif_free(job);
}

static ERL_NIF_TERM mm_ok(ErlNifEnv *e, ERL_NIF_TERM value) {
    return enif_make_tuple2(e, enif_make_atom(e, "ok"), value);
}

typedef struct {
    jlong duration_ms;
    jint width, height;
    jboolean has_audio, has_video;
    const jbyte *mime;
    jsize mime_len;
} mm_info;

static ERL_NIF_TERM mm_build_info(ErlNifEnv *e, void *arg) {
    mm_info *i = (mm_info *)arg;
    ERL_NIF_TERM mime;
    unsigned char *buf = enif_make_new_binary(e, (size_t)i->mime_len, &mime);
    if (i->mime_len > 0)
        memcpy(buf, i->mime, (size_t)i->mime_len);
    ERL_NIF_TERM t[6] = {
        enif_make_int64(e, i->duration_ms),
        enif_make_int(e, i->width),
        enif_make_int(e, i->height),
        enif_make_atom(e, i->has_audio ? "true" : "false"),
        enif_make_atom(e, i->has_video ? "true" : "false"),
        mime,
    };
    return mm_ok(e, enif_make_tuple_from_array(e, t, 6));
}

JNIEXPORT void JNICALL Java_io_mob_media_MobMediaBridge_nativeDeliverInfo(
    JNIEnv *jenv, jclass cls, jlong job, jlong duration_ms, jint width, jint height,
    jboolean has_audio, jboolean has_video, jbyteArray mime) {
    (void)cls;
    mm_info i = {duration_ms, width, height, has_audio, has_video, NULL, 0};
    jbyte *bytes = NULL;
    if (mime != NULL) {
        i.mime_len = (*jenv)->GetArrayLength(jenv, mime);
        bytes = (*jenv)->GetByteArrayElements(jenv, mime, NULL);
        if (bytes == NULL)
            i.mime_len = 0;
        i.mime = bytes;
    }
    mm_deliver(job, mm_build_info, &i);
    if (bytes != NULL)
        (*jenv)->ReleaseByteArrayElements(jenv, mime, bytes, JNI_ABORT);
}

static ERL_NIF_TERM mm_build_count(ErlNifEnv *e, void *arg) {
    return mm_ok(e, enif_make_int64(e, *(jlong *)arg));
}

JNIEXPORT void JNICALL Java_io_mob_media_MobMediaBridge_nativeDeliverCount(JNIEnv *jenv, jclass cls,
                                                                           jlong job, jlong count) {
    (void)jenv;
    (void)cls;
    mm_deliver(job, mm_build_count, &count);
}

static ERL_NIF_TERM mm_build_size(ErlNifEnv *e, void *arg) {
    jint *wh = (jint *)arg;
    return mm_ok(e, enif_make_tuple2(e, enif_make_int(e, wh[0]), enif_make_int(e, wh[1])));
}

JNIEXPORT void JNICALL Java_io_mob_media_MobMediaBridge_nativeDeliverSize(JNIEnv *jenv, jclass cls,
                                                                          jlong job, jint width,
                                                                          jint height) {
    (void)jenv;
    (void)cls;
    jint wh[2] = {width, height};
    mm_deliver(job, mm_build_size, wh);
}

static ERL_NIF_TERM mm_build_error(ErlNifEnv *e, void *arg) {
    jint code = *(jint *)arg;
    int n = (int)(sizeof(mm_reasons) / sizeof(mm_reasons[0]));
    const char *reason = (code > 0 && code < n) ? mm_reasons[code] : mm_reasons[0];
    return enif_make_tuple2(e, enif_make_atom(e, "error"), enif_make_atom(e, reason));
}

JNIEXPORT void JNICALL Java_io_mob_media_MobMediaBridge_nativeDeliverError(JNIEnv *jenv, jclass cls,
                                                                           jlong job, jint code) {
    (void)jenv;
    (void)cls;
    mm_deliver(job, mm_build_error, &code);
}

/* ── NIFs (called on a BEAM scheduler; they only queue the job) ────────── */

static ERL_NIF_TERM mm_jni_error(ErlNifEnv *env, const char *reason) {
    return enif_make_tuple2(
        env, enif_make_atom(env, "error"),
        enif_make_tuple2(env, enif_make_atom(env, "jni"), enif_make_atom(env, reason)));
}

/* A new local byte[] holding bin, or NULL (exception cleared). */
static jbyteArray mm_bytes(JNIEnv *jenv, const ErlNifBinary *bin) {
    if (bin->size > (size_t)INT32_MAX)
        return NULL;
    jbyteArray arr = (*jenv)->NewByteArray(jenv, (jsize)bin->size);
    if (arr == NULL || (*jenv)->ExceptionCheck(jenv)) {
        (*jenv)->ExceptionClear(jenv);
        return NULL;
    }
    (*jenv)->SetByteArrayRegion(jenv, arr, 0, (jsize)bin->size, (const jbyte *)bin->data);
    if ((*jenv)->ExceptionCheck(jenv)) {
        (*jenv)->ExceptionClear(jenv);
        (*jenv)->DeleteLocalRef(jenv, arr);
        return NULL;
    }
    return arr;
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

static void mm_job_free(mm_job *job) {
    enif_free_env(job->env);
    enif_free(job);
}

/* The arguments every operation shares, already checked. */
typedef struct {
    ErlNifBinary path;
    ErlNifBinary out; /* size 0 for info */
    int ints[3];
    ErlNifSInt64 at_ms;
} mm_args;

enum mm_op { MM_INFO, MM_AUDIO_PCM, MM_FRAME };

static ERL_NIF_TERM mm_start(ErlNifEnv *env, ERL_NIF_TERM ref, enum mm_op op, mm_args *a) {
    if (g_cls == NULL)
        return mm_jni_error(env, "bridge_not_registered");

    int attached = 0;
    JNIEnv *jenv = get_jenv(&attached);
    if (!jenv)
        return mm_jni_error(env, "no_jenv");

    ERL_NIF_TERM result = enif_make_atom(env, "ok");
    mm_job *job = NULL;
    jlong handle = 0;
    jbyteArray jpath = mm_bytes(jenv, &a->path);
    jbyteArray jout = (jpath && op != MM_INFO) ? mm_bytes(jenv, &a->out) : NULL;
    if (!jpath || (op != MM_INFO && !jout)) {
        result = mm_jni_error(env, "alloc");
        goto done;
    }

    job = mm_job_new(env, ref);
    if (job == NULL) {
        result = mm_jni_error(env, "alloc");
        goto done;
    }

    handle = (jlong)(intptr_t)job;
    switch (op) {
    case MM_INFO:
        (*jenv)->CallStaticVoidMethod(jenv, g_cls, g_info, handle, jpath);
        break;
    case MM_AUDIO_PCM:
        (*jenv)->CallStaticVoidMethod(jenv, g_cls, g_audio_pcm, handle, jpath, jout,
                                      (jint)a->ints[0], (jint)a->ints[1]);
        break;
    case MM_FRAME:
        (*jenv)->CallStaticVoidMethod(jenv, g_cls, g_frame, handle, jpath, jout, (jlong)a->at_ms,
                                      (jint)a->ints[0], (jint)a->ints[1]);
        break;
    }

    if ((*jenv)->ExceptionCheck(jenv)) {
        /* Nothing was queued: the job is still ours. */
        (*jenv)->ExceptionClear(jenv);
        mm_job_free(job);
        result = mm_jni_error(env, "call_failed");
    }

done:
    if (jpath)
        (*jenv)->DeleteLocalRef(jenv, jpath);
    if (jout)
        (*jenv)->DeleteLocalRef(jenv, jout);
    if (attached)
        (*g_jvm)->DetachCurrentThread(g_jvm);
    return result;
}

static int mm_path(ErlNifEnv *env, ERL_NIF_TERM term, ErlNifBinary *bin) {
    /* A path with a NUL can't name a file; refuse it rather than truncate. */
    return enif_inspect_binary(env, term, bin) && bin->size > 0 &&
           memchr(bin->data, 0, bin->size) == NULL;
}

static ERL_NIF_TERM mm_available(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    return enif_make_atom(env, "true");
}

static ERL_NIF_TERM mm_info_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    mm_args a = {0};
    if (!enif_is_ref(env, argv[0]) || !mm_path(env, argv[1], &a.path))
        return enif_make_badarg(env);
    return mm_start(env, argv[0], MM_INFO, &a);
}

static ERL_NIF_TERM mm_audio_pcm_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    mm_args a = {0};
    if (!enif_is_ref(env, argv[0]) || !mm_path(env, argv[1], &a.path) ||
        !mm_path(env, argv[2], &a.out) || !enif_get_int(env, argv[3], &a.ints[0]) ||
        !enif_get_int(env, argv[4], &a.ints[1]) || a.ints[0] <= 0 || a.ints[1] < 1 || a.ints[1] > 2)
        return enif_make_badarg(env);
    return mm_start(env, argv[0], MM_AUDIO_PCM, &a);
}

static ERL_NIF_TERM mm_frame_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    mm_args a = {0};
    if (!enif_is_ref(env, argv[0]) || !mm_path(env, argv[1], &a.path) ||
        !mm_path(env, argv[2], &a.out) || !enif_get_int64(env, argv[3], &a.at_ms) ||
        !enif_get_int(env, argv[4], &a.ints[0]) || !enif_get_int(env, argv[5], &a.ints[1]) ||
        a.at_ms < 0 || a.ints[0] < 0 || a.ints[1] < 1 || a.ints[1] > 100)
        return enif_make_badarg(env);
    return mm_start(env, argv[0], MM_FRAME, &a);
}

static ErlNifFunc nif_funcs[] = {
    {"available", 0, mm_available, 0},
    {"info", 2, mm_info_nif, 0},
    {"audio_pcm", 5, mm_audio_pcm_nif, 0},
    {"frame", 6, mm_frame_nif, 0},
};

ERL_NIF_INIT(mob_media_nif, nif_funcs, NULL, NULL, NULL, NULL)
