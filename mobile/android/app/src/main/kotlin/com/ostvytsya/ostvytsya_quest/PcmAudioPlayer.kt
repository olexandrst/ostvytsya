package com.ostvytsya.ostvytsya_quest

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import android.os.HandlerThread
import android.util.Log

/**
 * Мінімальний самописний потоковий PCM16-плеєр на AudioTrack — заміна
 * плеєра flutter_sound, який спричинив ТРИ підтверджені нативні SIGSEGV
 * на реальному пристрої (AudioTrack.write() -> AudioTrack::releaseBuffer(),
 * null pointer dereference), навіть після того, як мікрофон перестав
 * працювати одночасно з ним. Проблема виявилась у самому плеєрі.
 *
 * Усі виклики (write/stop/release) серіалізовано через ОДИН HandlerThread —
 * write() ніколи не може перетнутися зі stop()/release() того самого
 * AudioTrack. Саме таке перетинання (запис у момент звільнення) —
 * класична причина подібних падінь у нативному аудіо-стеку Android.
 * Якщо AudioTrack ще не готовий (гонитва на старті) — write() просто
 * нічого не робить, замість падіння.
 */
class PcmAudioPlayer {
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var audioTrack: AudioTrack? = null

    fun start(sampleRate: Int) {
        stop()
        val t = HandlerThread("PcmAudioPlayer").apply { start() }
        thread = t
        val h = Handler(t.looper)
        handler = h
        h.post {
            try {
                val minBuf = AudioTrack.getMinBufferSize(
                    sampleRate,
                    AudioFormat.CHANNEL_OUT_MONO,
                    AudioFormat.ENCODING_PCM_16BIT
                )
                val bufSize = if (minBuf > 0) minBuf * 2 else sampleRate * 2
                val track = AudioTrack(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                    bufSize,
                    AudioTrack.MODE_STREAM,
                    AudioManager.AUDIO_SESSION_ID_GENERATE
                )
                track.play()
                audioTrack = track
            } catch (err: Throwable) {
                Log.e(TAG, "Не вдалося створити AudioTrack", err)
                audioTrack = null
            }
        }
    }

    fun write(bytes: ByteArray) {
        val h = handler ?: return
        h.post {
            val track = audioTrack ?: return@post
            try {
                track.write(bytes, 0, bytes.size)
            } catch (err: Throwable) {
                Log.e(TAG, "Помилка запису в AudioTrack", err)
            }
        }
    }

    fun stop() {
        val h = handler ?: return
        val t = thread
        // Скидаємо ВСІ ще не виконані write() — інакше quitSafely() чекає,
        // поки серіалізована черга дограє геть усю накопичену репліку
        // персонажа (могло бути кілька секунд), і кнопка "Зупинити" реагує
        // з відчутною затримкою. Лишається щонайбільше один write(), що вже
        // виконується прямо зараз (і сам скоро розблокується, бо звільнення
        // буфера AudioTrack — питання мілісекунд, а не секунд).
        h.removeCallbacksAndMessages(null)
        h.post { releaseTrack() }
        t?.quitSafely()
        thread = null
        handler = null
    }

    private fun releaseTrack() {
        try {
            audioTrack?.let {
                it.stop()
                it.release()
            }
        } catch (err: Throwable) {
            Log.e(TAG, "Помилка зупинки AudioTrack", err)
        } finally {
            audioTrack = null
        }
    }

    companion object {
        private const val TAG = "PcmAudioPlayer"
    }
}
