// mob_media plugin — Android bridge.
//
// The C NIF (priv/native/jni/mob_media_nif.c) calls info / audioPcm / frame
// with a job handle; each queues its work on this bridge's own threads and
// returns at once. Every queued job ends in exactly one nativeDeliver* call
// with that handle (the C side frees the job there). If one of these methods
// throws, nothing was queued and the C side frees the job itself.
//
// The generated MobPluginBootstrap.registerAll runs register() from
// MainActivity.onCreate before the BEAM starts, so nativeRegister caches this
// class and its method IDs while the app class loader is on the stack.
//
//   info      MediaExtractor (tracks, durations, sizes) + MediaMetadataRetriever
//             (container MIME type, duration, size, rotation)
//   audioPcm  MediaExtractor + MediaCodec, streamed through PcmSink (channel
//             mapping and resampling, the algorithm MobMedia.PCM documents and
//             implements in Elixir) into the output file
//   frame     MediaMetadataRetriever.getScaledFrameAtTime / getFrameAtTime
//             (OPTION_CLOSEST: the exact frame) + Bitmap.compress(JPEG)
package io.mob.media

import android.graphics.Bitmap
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.util.Log
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

object MobMediaBridge {
    private const val TAG = "MobMedia"

    // Error codes. mob_media_nif.c's mm_reasons maps them to atoms by index:
    // keep the two in step.
    const val E_NOT_FOUND = 1
    const val E_UNSUPPORTED = 2
    const val E_NO_AUDIO = 3
    const val E_NO_VIDEO = 4
    const val E_DECODE_FAILED = 5
    const val E_IO_ERROR = 6

    // Two workers: a long audio decode doesn't hold up a frame grab behind it.
    // Daemon threads, below normal priority: never in the way of the UI.
    private val pool: ExecutorService = Executors.newFixedThreadPool(2) { r ->
        Thread(r, "mob_media").apply {
            isDaemon = true
            priority = Thread.NORM_PRIORITY - 1
        }
    }

    @JvmStatic external fun nativeRegister()

    @JvmStatic external fun nativeDeliverInfo(
        job: Long, durationMs: Long, width: Int, height: Int,
        hasAudio: Boolean, hasVideo: Boolean, mime: ByteArray
    )

    @JvmStatic external fun nativeDeliverCount(job: Long, count: Long)

    @JvmStatic external fun nativeDeliverSize(job: Long, width: Int, height: Int)

    @JvmStatic external fun nativeDeliverError(job: Long, code: Int)

    @JvmStatic
    fun register() {
        nativeRegister()
    }

    private class Failure(val code: Int, message: String, cause: Throwable? = null) :
        Exception(message, cause)

    private class Info(
        val durationMs: Long, val width: Int, val height: Int,
        val hasAudio: Boolean, val hasVideo: Boolean, val mime: String
    )

    private class Size(val width: Int, val height: Int)

    // ── Entry points (called from the NIF on a BEAM thread) ────────────────

    @JvmStatic
    fun info(job: Long, path: ByteArray) = submit(job) { probe(str(path)) }

    @JvmStatic
    fun audioPcm(job: Long, path: ByteArray, out: ByteArray, rate: Int, channels: Int) =
        submit(job) { decodeAudio(str(path), str(out), rate, channels) }

    @JvmStatic
    fun frame(job: Long, path: ByteArray, out: ByteArray, atMs: Long, maxPx: Int, quality: Int) =
        submit(job) { grabFrame(str(path), str(out), atMs, maxPx, quality) }

    // Paths cross JNI as UTF-8 bytes (NewStringUTF's modified UTF-8 would
    // mangle characters outside the BMP).
    private fun str(bytes: ByteArray) = String(bytes, Charsets.UTF_8)

    // execute() is the last thing that can throw: if it does, nothing was
    // queued and the NIF frees the job. Once queued, the job is delivered
    // exactly once, whatever the work throws.
    private fun submit(job: Long, work: () -> Any) {
        pool.execute {
            val result: Any = try {
                work()
            } catch (f: Failure) {
                Log.w(TAG, f.message ?: "failed", f.cause)
                f
            } catch (t: Throwable) {
                Log.e(TAG, "unexpected failure", t)
                Failure(E_DECODE_FAILED, "unexpected", t)
            }

            when (result) {
                is Info -> nativeDeliverInfo(
                    job, result.durationMs, result.width, result.height,
                    result.hasAudio, result.hasVideo, result.mime.toByteArray(Charsets.UTF_8)
                )
                is Long -> nativeDeliverCount(job, result)
                is Size -> nativeDeliverSize(job, result.width, result.height)
                is Failure -> nativeDeliverError(job, result.code)
                else -> nativeDeliverError(job, E_DECODE_FAILED)
            }
        }
    }

    private fun requireFile(path: String) {
        if (!File(path).isFile) throw Failure(E_NOT_FOUND, "no such file: $path")
    }

    private fun extractor(path: String): MediaExtractor {
        requireFile(path)
        val ex = MediaExtractor()
        try {
            ex.setDataSource(path)
        } catch (e: Exception) {
            ex.release()
            throw Failure(E_UNSUPPORTED, "can't open $path", e)
        }
        if (ex.trackCount == 0) {
            ex.release()
            throw Failure(E_UNSUPPORTED, "no tracks in $path")
        }
        return ex
    }

    // null when the platform's retriever can't open the file.
    private fun retriever(path: String): MediaMetadataRetriever? {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(path)
            r
        } catch (e: Exception) {
            r.release()
            null
        }
    }

    private fun MediaMetadataRetriever.int(key: Int): Int? = extractMetadata(key)?.toIntOrNull()
    private fun MediaMetadataRetriever.long(key: Int): Long? = extractMetadata(key)?.toLongOrNull()

    private fun MediaFormat.mime(): String = getString(MediaFormat.KEY_MIME) ?: ""
    private fun MediaFormat.int(key: String): Int? = if (containsKey(key)) getInteger(key) else null

    // ── info ───────────────────────────────────────────────────────────────

    private fun probe(path: String): Info {
        var durationUs = -1L
        var hasAudio = false
        var hasVideo = false
        var width = 0
        var height = 0
        var rotation = 0

        val ex = extractor(path)
        try {
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                val mime = f.mime()
                if (f.containsKey(MediaFormat.KEY_DURATION))
                    durationUs = maxOf(durationUs, f.getLong(MediaFormat.KEY_DURATION))
                if (mime.startsWith("audio/")) hasAudio = true
                if (mime.startsWith("video/") && !hasVideo) {
                    hasVideo = true
                    width = f.int(MediaFormat.KEY_WIDTH) ?: 0
                    height = f.int(MediaFormat.KEY_HEIGHT) ?: 0
                    rotation = f.int(MediaFormat.KEY_ROTATION) ?: 0
                }
            }
        } finally {
            ex.release()
        }

        var durationMs = if (durationUs >= 0) durationUs / 1000 else -1L
        var mime = ""
        retriever(path)?.let { r ->
            try {
                mime = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE) ?: ""
                r.long(MediaMetadataRetriever.METADATA_KEY_DURATION)?.let { durationMs = it }
                if (hasVideo) {
                    r.int(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.let { width = it }
                    r.int(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.let { height = it }
                    r.int(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.let { rotation = it }
                }
            } finally {
                r.release()
            }
        }

        // Report the size the video is shown at.
        if (rotation % 180 != 0) width = height.also { height = width }
        return Info(durationMs, width, height, hasAudio, hasVideo, mime)
    }

    // ── audioPcm ───────────────────────────────────────────────────────────

    private fun decodeAudio(path: String, out: String, rate: Int, channels: Int): Long {
        val ex = extractor(path)
        var codec: MediaCodec? = null
        try {
            val track = (0 until ex.trackCount).firstOrNull {
                ex.getTrackFormat(it).mime().startsWith("audio/")
            } ?: throw Failure(E_NO_AUDIO, "no audio track in $path")

            ex.selectTrack(track)
            val format = ex.getTrackFormat(track)
            val decoder = try {
                MediaCodec.createDecoderByType(format.mime())
            } catch (e: Exception) {
                throw Failure(E_UNSUPPORTED, "no decoder for ${format.mime()}", e)
            }
            codec = decoder
            try {
                decoder.configure(format, null, null, 0)
                decoder.start()
            } catch (e: Exception) {
                throw Failure(E_UNSUPPORTED, "can't start the ${format.mime()} decoder", e)
            }

            val stream = try {
                FileOutputStream(out)
            } catch (e: IOException) {
                throw Failure(E_IO_ERROR, "can't write $out", e)
            }

            PcmSink(stream, rate, channels).use { sink ->
                pump(ex, decoder, format, sink)
                sink.finish()
                return sink.bytes
            }
        } finally {
            try {
                codec?.stop()
            } catch (_: Exception) {
            }
            codec?.release()
            ex.release()
        }
    }

    private fun pump(ex: MediaExtractor, codec: MediaCodec, input: MediaFormat, sink: PcmSink) {
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var idle = 0

        while (true) {
            // Queue every input buffer the decoder has free, without waiting.
            var fed = false
            while (!inputDone) {
                val i = codec.dequeueInputBuffer(0)
                if (i < 0) break
                val buf = codec.getInputBuffer(i)!!
                val n = ex.readSampleData(buf, 0)
                if (n < 0) {
                    codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    inputDone = true
                } else {
                    codec.queueInputBuffer(i, 0, n, ex.sampleTime, 0)
                    ex.advance()
                }
                fed = true
            }

            // Wait for output only when there was nothing to feed.
            val o = codec.dequeueOutputBuffer(info, if (fed) 0L else 5_000L)
            when {
                o >= 0 -> {
                    idle = 0
                    if (!sink.configured) sink.configure(codec.outputFormat, input)
                    if (info.size > 0) {
                        val buf = codec.getOutputBuffer(o)!!
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        sink.write(buf)
                    }
                    codec.releaseOutputBuffer(o, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
                o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    idle = 0
                    sink.configure(codec.outputFormat, input)
                }
                // A decoder that stops answering after end of input would
                // otherwise spin here forever: give up after ~10 s of silence.
                inputDone && ++idle > 2_000 ->
                    throw Failure(E_DECODE_FAILED, "decoder never reached end of stream")
            }
        }
    }

    // Decoded PCM in, s16le at (rate, channels) out. Mirrors MobMedia.PCM:
    // channels mapped first (to mono: the truncated average; mono to stereo:
    // duplicated; more to stereo: the first two), then each channel resampled
    // (down: box average of input frames [k*in/out, (k+1)*in/out); up: linear
    // interpolation at k*in/out, rounded half up). Integer maths only, so the
    // streamed result equals the Elixir reference byte for byte.
    //
    // Each decoder buffer is processed as a block in tight loops with no
    // per-sample calls: a debuggable app (every dev build) runs this code
    // in ART's interpreter/JIT, where a call per sample costs seconds a
    // minute of audio.
    private class PcmSink(private val stream: OutputStream, val outRate: Int, val outChannels: Int) :
        Closeable {
        private val outBuf = ByteArray(1 shl 16)
        private var outPos = 0
        var bytes = 0L
            private set
        var configured = false
            private set

        private var inRate = 0
        private var inChannels = 0
        private var encoding = AudioFormat.ENCODING_PCM_16BIT

        // Resampler state for the current run (since the last configure).
        private var n = 0L // input frames seen
        private var k = 0L // output frames emitted
        private var boundary = 0L // downsampling: n that completes box k
        private var acc0 = 0L
        private var acc1 = 0L
        private var accCount = 0
        private var prev0 = 0 // upsampling: input frame n - 1
        private var prev1 = 0

        private var pcm16 = ShortArray(0)
        private var src = IntArray(0) // one buffer's samples, interleaved
        private var mapped = IntArray(0) // its frames, mapped to outChannels
        private val scratch = ByteArray(4)

        fun configure(f: MediaFormat, input: MediaFormat) {
            val rate = f.int(MediaFormat.KEY_SAMPLE_RATE)
                ?: input.int(MediaFormat.KEY_SAMPLE_RATE)
                ?: throw Failure(E_UNSUPPORTED, "no sample rate")
            val ch = f.int(MediaFormat.KEY_CHANNEL_COUNT)
                ?: input.int(MediaFormat.KEY_CHANNEL_COUNT)
                ?: throw Failure(E_UNSUPPORTED, "no channel count")
            val enc = f.int(MediaFormat.KEY_PCM_ENCODING) ?: AudioFormat.ENCODING_PCM_16BIT
            if (rate < 1 || ch < 1) throw Failure(E_UNSUPPORTED, "$rate Hz, $ch channels")
            bytesPerSample(enc)
            if (configured && rate == inRate && ch == inChannels && enc == encoding) return

            // A mid-stream change (rare: e.g. HE-AAC signalled late) ends the
            // current run; the new one starts its own resampling grid.
            if (configured) tail()
            inRate = rate
            inChannels = ch
            encoding = enc
            n = 0
            k = 0
            boundary = inRate.toLong() / outRate
            acc0 = 0
            acc1 = 0
            accCount = 0
            configured = true
        }

        fun write(buf: ByteBuffer) {
            buf.order(ByteOrder.LITTLE_ENDIAN)
            val frames = buf.remaining() / (bytesPerSample(encoding) * inChannels)
            val samples = frames * inChannels
            if (src.size < samples) src = IntArray(samples)
            if (mapped.size < frames * outChannels) mapped = IntArray(frames * outChannels)
            read(buf, samples)
            map(frames)
            resample(frames)
        }

        // Input samples as 16-bit values into src.
        private fun read(buf: ByteBuffer, samples: Int) {
            val s = src
            if (encoding == AudioFormat.ENCODING_PCM_16BIT) {
                if (pcm16.size < samples) pcm16 = ShortArray(samples)
                buf.asShortBuffer().get(pcm16, 0, samples)
                val p = pcm16
                for (i in 0 until samples) s[i] = p[i].toInt()
                return
            }
            for (i in 0 until samples) {
                s[i] = when (encoding) {
                    AudioFormat.ENCODING_PCM_8BIT -> ((buf.get().toInt() and 0xFF) - 128) shl 8
                    AudioFormat.ENCODING_PCM_FLOAT ->
                        (buf.float.coerceIn(-1f, 1f) * 32767f).toInt()
                    ENCODING_PCM_24BIT_PACKED -> {
                        buf.get(scratch, 0, 3)
                        // The top byte carries the sign; the low byte is dropped.
                        (scratch[2].toInt() shl 8) or (scratch[1].toInt() and 0xFF)
                    }
                    else -> buf.int shr 16 // ENCODING_PCM_32BIT
                }
            }
        }

        private fun map(frames: Int) {
            val s = src
            val m = mapped
            val ic = inChannels
            when {
                outChannels == 1 && ic == 1 -> System.arraycopy(s, 0, m, 0, frames)
                outChannels == 1 -> for (f in 0 until frames) {
                    var sum = 0
                    val base = f * ic
                    for (c in 0 until ic) sum += s[base + c]
                    m[f] = sum / ic
                }
                ic == 1 -> for (f in 0 until frames) {
                    m[2 * f] = s[f]
                    m[2 * f + 1] = s[f]
                }
                else -> for (f in 0 until frames) {
                    m[2 * f] = s[f * ic]
                    m[2 * f + 1] = s[f * ic + 1]
                }
            }
        }

        private fun resample(frames: Int) {
            val m = mapped
            val oc = outChannels
            val stereo = oc == 2
            when {
                inRate == outRate -> {
                    for (i in 0 until frames * oc) put(m[i])
                    n += frames
                    k += frames
                }
                inRate > outRate -> for (f in 0 until frames) {
                    acc0 += m[f * oc]
                    if (stereo) acc1 += m[f * oc + 1]
                    accCount++
                    n++
                    if (n == boundary) {
                        put((acc0 / accCount).toInt())
                        if (stereo) put((acc1 / accCount).toInt())
                        acc0 = 0
                        acc1 = 0
                        accCount = 0
                        k++
                        boundary = (k + 1) * inRate / outRate
                    }
                }
                else -> for (f in 0 until frames) {
                    val c0 = m[f * oc]
                    val c1 = if (stereo) m[f * oc + 1] else 0
                    if (n > 0) interpolateUntil(n * outRate, c0, c1)
                    prev0 = c0
                    prev1 = c1
                    n++
                }
            }
        }

        // Emit outputs at positions k*in/out in [n-1, limit/out), between
        // prev (frame n - 1) and (b0, b1).
        private fun interpolateUntil(limit: Long, b0: Int, b1: Int) {
            val base = (n - 1) * outRate
            val twoOut = 2L * outRate
            while (k * inRate < limit) {
                val num = k * inRate - base
                put((prev0 + Math.floorDiv(2L * (b0 - prev0) * num + outRate, twoOut)).toInt())
                if (outChannels == 2)
                    put((prev1 + Math.floorDiv(2L * (b1 - prev1) * num + outRate, twoOut)).toInt())
                k++
            }
        }

        // End of a run: upsampling still owes the outputs after the last
        // input frame, which stands alone.
        private fun tail() {
            if (inRate < outRate && n > 0) interpolateUntil(n * outRate, prev0, prev1)
        }

        // One output sample. Averages and interpolations of 16-bit values
        // stay in range, so there's nothing to clamp.
        private fun put(s: Int) {
            if (outPos + 2 > outBuf.size) flushBuffer()
            outBuf[outPos] = s.toByte()
            outBuf[outPos + 1] = (s shr 8).toByte()
            outPos += 2
            bytes += 2
        }

        private fun flushBuffer() {
            try {
                stream.write(outBuf, 0, outPos)
            } catch (e: IOException) {
                throw Failure(E_IO_ERROR, "write failed", e)
            }
            outPos = 0
        }

        fun finish() {
            if (configured) tail()
            flushBuffer()
            try {
                stream.flush()
            } catch (e: IOException) {
                throw Failure(E_IO_ERROR, "write failed", e)
            }
        }

        override fun close() {
            try {
                stream.close()
            } catch (_: IOException) {
            }
        }

        companion object {
            // AudioFormat constants added in API 31; the values are fixed.
            const val ENCODING_PCM_24BIT_PACKED = 21
            const val ENCODING_PCM_32BIT = 22

            fun bytesPerSample(encoding: Int): Int = when (encoding) {
                AudioFormat.ENCODING_PCM_16BIT -> 2
                AudioFormat.ENCODING_PCM_8BIT -> 1
                AudioFormat.ENCODING_PCM_FLOAT -> 4
                ENCODING_PCM_24BIT_PACKED -> 3
                ENCODING_PCM_32BIT -> 4
                else -> throw Failure(E_UNSUPPORTED, "PCM encoding $encoding")
            }
        }
    }

    // ── frame ──────────────────────────────────────────────────────────────

    private fun grabFrame(path: String, out: String, atMs: Long, maxPx: Int, quality: Int): Size {
        // The extractor says whether there's a video track at all (the
        // retriever refuses some audio-only files outright).
        val ex = extractor(path)
        val hasVideo = try {
            (0 until ex.trackCount).any { ex.getTrackFormat(it).mime().startsWith("video/") }
        } finally {
            ex.release()
        }
        if (!hasVideo) throw Failure(E_NO_VIDEO, "no video track in $path")

        val r = retriever(path) ?: throw Failure(E_UNSUPPORTED, "can't open $path")
        try {
            val duration = r.long(MediaMetadataRetriever.METADATA_KEY_DURATION)
            val t = if (duration != null && atMs > duration) duration else atMs
            val longest = maxOf(
                r.int(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH) ?: 0,
                r.int(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT) ?: 0
            )

            val bitmap = frameAt(r, t * 1000, if (maxPx in 1 until longest) maxPx else 0)
                ?: throw Failure(E_DECODE_FAILED, "no frame at $t ms in $path")
            try {
                writeJpeg(bitmap, out, quality)
                return Size(bitmap.width, bitmap.height)
            } finally {
                bitmap.recycle()
            }
        } finally {
            r.release()
        }
    }

    // The exact frame at timeUs, upright, scaled to fit a maxPx square (0:
    // full size). At or past the last frame OPTION_CLOSEST can come back
    // empty; the previous sync frame is the fallback.
    private fun frameAt(r: MediaMetadataRetriever, timeUs: Long, maxPx: Int): Bitmap? {
        fun at(option: Int): Bitmap? =
            if (maxPx > 0) r.getScaledFrameAtTime(timeUs, option, maxPx, maxPx)
            else r.getFrameAtTime(timeUs, option)

        return at(MediaMetadataRetriever.OPTION_CLOSEST)
            ?: at(MediaMetadataRetriever.OPTION_PREVIOUS_SYNC)
    }

    private fun writeJpeg(bitmap: Bitmap, out: String, quality: Int) {
        val ok = try {
            FileOutputStream(out).use { bitmap.compress(Bitmap.CompressFormat.JPEG, quality, it) }
        } catch (e: IOException) {
            throw Failure(E_IO_ERROR, "can't write $out", e)
        }
        if (!ok) throw Failure(E_IO_ERROR, "JPEG encoding failed")
    }
}
