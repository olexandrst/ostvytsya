package com.ostvytsya.ostvytsya_quest

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.util.Log
import java.nio.ByteBuffer

/**
 * Кодує потік моно PCM16 у AAC-LC і мультиплексує в .m4a на льоту —
 * замінює нестиснений WAV (який для 30-хвилинної сесії на 24 кГц важив
 * ~86 МБ) стисненим файлом (~48 кбіт/с, ~11 МБ на ту саму тривалість).
 * MediaCodec/MediaMuxer замість стороннього Flutter-плагіна — той самий
 * підхід, що й у PcmAudioPlayer (одного разу вже довелось прибрати
 * flutter_sound через нативні SIGSEGV), і той самий патерн серіалізації
 * викликів через один HandlerThread.
 *
 * На відміну від PcmAudioPlayer.stop() (яка навмисно ВІДКИДАЄ ще не
 * виконані write(), щоб кнопка "Зупинити" не гальмувала), stop() тут
 * ніколи не скидає чергу — інакше хвіст розмови (напр. саме слово
 * перемоги) просто не потрапить у файл.
 */
class SessionAacEncoder {
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var codec: MediaCodec? = null
    private var muxer: MediaMuxer? = null
    private var trackIndex = -1
    private var muxerStarted = false
    private var sampleRate = 24000
    private var totalPresentationTimeUs = 0L
    private val bufferInfo = MediaCodec.BufferInfo()
    // Тримаємо дескриптор відкритим на весь час запису й закриваємо разом із
    // мультиплексором — інакше файл у медіатеці лишиться обрізаним.
    private var outputPfd: ParcelFileDescriptor? = null

    /**
     * Писати у звичайний файл за шляхом (стара поведінка, Android 9 і нижче).
     */
    fun start(path: String, sampleRate: Int) = startInternal(sampleRate) {
        MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    }

    /**
     * Писати у вже відкритий дескриптор — так пишемо в спільну медіатеку
     * (MediaStore), звідки записи не зникають при видаленні застосунку.
     */
    fun start(pfd: ParcelFileDescriptor, sampleRate: Int) {
        outputPfd = pfd
        startInternal(sampleRate) {
            // MediaMuxer із дескриптора — з Android 8. Практично недосяжна
            // гілка (дескриптор дає лише MediaStore, а це вже Android 10+),
            // але перевірка потрібна явно: без неї лінт NewApi завалить
            // release-збірку.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                MediaMuxer(pfd.fileDescriptor, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            } else {
                throw UnsupportedOperationException("Потрібен Android 8+")
            }
        }
    }

    private fun startInternal(sampleRate: Int, makeMuxer: () -> MediaMuxer) {
        val t = HandlerThread("SessionAacEncoder").apply { start() }
        thread = t
        val h = Handler(t.looper)
        handler = h
        h.post {
            try {
                this.sampleRate = sampleRate
                totalPresentationTimeUs = 0L
                trackIndex = -1
                muxerStarted = false
                val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, 1)
                format.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                format.setInteger(MediaFormat.KEY_BIT_RATE, 48000)
                val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
                enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                enc.start()
                codec = enc
                muxer = makeMuxer()
            } catch (err: Throwable) {
                Log.e(TAG, "Не вдалося запустити AAC-кодер", err)
                codec = null
                muxer = null
            }
        }
    }

    fun write(bytes: ByteArray) {
        val h = handler ?: return
        h.post { encodeChunk(bytes) }
    }

    private fun encodeChunk(bytes: ByteArray) {
        val enc = codec ?: return
        try {
            var offset = 0
            while (offset < bytes.size) {
                val inIndex = enc.dequeueInputBuffer(10_000)
                if (inIndex < 0) {
                    drainEncoder(false)
                    continue
                }
                val inputBuffer: ByteBuffer = enc.getInputBuffer(inIndex) ?: break
                inputBuffer.clear()
                val chunkSize = minOf(inputBuffer.capacity(), bytes.size - offset)
                inputBuffer.put(bytes, offset, chunkSize)
                val presentationTimeUs = totalPresentationTimeUs
                // 2 байти на семпл, моно.
                val durationUs = (chunkSize / 2).toLong() * 1_000_000L / sampleRate
                totalPresentationTimeUs += durationUs
                enc.queueInputBuffer(inIndex, 0, chunkSize, presentationTimeUs, 0)
                offset += chunkSize
                drainEncoder(false)
            }
        } catch (err: Throwable) {
            Log.e(TAG, "Помилка кодування AAC", err)
        }
    }

    private fun drainEncoder(endOfStream: Boolean) {
        val enc = codec ?: return
        val mux = muxer ?: return
        if (endOfStream) {
            try {
                val inIndex = enc.dequeueInputBuffer(10_000)
                if (inIndex >= 0) {
                    enc.queueInputBuffer(inIndex, 0, 0, totalPresentationTimeUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                }
            } catch (err: Throwable) {
                Log.e(TAG, "Помилка сигналу кінця потоку", err)
            }
        }
        while (true) {
            val outIndex = enc.dequeueOutputBuffer(bufferInfo, 10_000)
            when {
                outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (muxerStarted) return
                    trackIndex = mux.addTrack(enc.outputFormat)
                    mux.start()
                    muxerStarted = true
                }
                outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) return
                    // При завершенні чекаємо, поки кодер сам не поверне EOS-кадр.
                }
                outIndex >= 0 -> {
                    val outputBuffer = enc.getOutputBuffer(outIndex)
                    if (outputBuffer != null && bufferInfo.size > 0 && muxerStarted) {
                        outputBuffer.position(bufferInfo.offset)
                        outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                        mux.writeSampleData(trackIndex, outputBuffer, bufferInfo)
                    }
                    enc.releaseOutputBuffer(outIndex, false)
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        return
                    }
                }
            }
        }
    }

    /**
     * Дописати все, що лишилось у черзі, домкнути AAC-потік і закрити
     * .m4a-файл. [onDone] викликається на цьому ж (не UI) потоці, коли
     * файл вже повністю записаний і закритий.
     */
    fun stop(onDone: () -> Unit) {
        val h = handler
        val t = thread
        thread = null
        handler = null
        if (h == null) {
            onDone()
            return
        }
        h.post {
            try {
                drainEncoder(true)
            } catch (err: Throwable) {
                Log.e(TAG, "Помилка завершення кодування", err)
            } finally {
                releaseAll()
            }
            onDone()
        }
        t?.quitSafely()
    }

    private fun releaseAll() {
        try {
            codec?.stop()
        } catch (err: Throwable) {
            Log.e(TAG, "Помилка зупинки кодера", err)
        }
        try {
            codec?.release()
        } catch (err: Throwable) {
            Log.e(TAG, "Помилка звільнення кодера", err)
        }
        try {
            if (muxerStarted) muxer?.stop()
        } catch (err: Throwable) {
            Log.e(TAG, "Помилка зупинки мультиплексора", err)
        }
        try {
            muxer?.release()
        } catch (err: Throwable) {
            Log.e(TAG, "Помилка звільнення мультиплексора", err)
        }
        // Лише ПІСЛЯ release() мультиплексора — доти він ще дописує в цей
        // дескриптор, і передчасне закриття обрізало б файл.
        try {
            outputPfd?.close()
        } catch (err: Throwable) {
            Log.e(TAG, "Помилка закриття дескриптора запису", err)
        }
        outputPfd = null
        codec = null
        muxer = null
    }

    companion object {
        private const val TAG = "SessionAacEncoder"
    }
}
