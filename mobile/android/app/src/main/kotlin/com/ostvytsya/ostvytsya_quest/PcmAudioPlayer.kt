package com.ostvytsya.ostvytsya_quest

import android.content.Context
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

    /**
     * [voiceCommunication] — відтворювати як голос розмови, а не як медіа.
     *
     * Це принципово для Bluetooth-ГАРНІТУРИ: щойно піднято SCO (а його
     * піднімає плагін `record` заради мікрофона гарнітури), профіль A2DP
     * призупиняється, і потік із USAGE_MEDIA у гарнітуру просто не
     * потрапляє — тиша без жодної помилки. Голос розмови
     * (USAGE_VOICE_COMMUNICATION) іде саме тим самим каналом SCO, що й
     * мікрофон, тож персонажа чути.
     *
     * Для звичайної Bluetooth-КОЛОНКИ (A2DP, без мікрофона) SCO не
     * піднімається взагалі — там лишається USAGE_MEDIA і повноцінна якість.
     */
    fun start(sampleRate: Int, voiceCommunication: Boolean = false) {
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
                        .setUsage(
                            if (voiceCommunication) AudioAttributes.USAGE_VOICE_COMMUNICATION
                            else AudioAttributes.USAGE_MEDIA
                        )
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

    /**
     * Прив'язати вихід до конкретного пристрою "на льоту" — AudioTrack
     * підтримує зміну preferredDevice без зупинки чи перестворення (звук не
     * переривається). null знімає прив'язку — система сама вибирає
     * найкращий доступний пристрій.
     */
    fun setPreferredDevice(context: Context, deviceId: Int?) {
        val h = handler ?: return
        h.post {
            val track = audioTrack ?: return@post
            try {
                val device = if (deviceId == null) {
                    null
                } else {
                    AudioDeviceUtils.findDevice(context, "output", deviceId)
                }
                track.setPreferredDevice(device)
            } catch (err: Throwable) {
                Log.e(TAG, "Не вдалося встановити пристрій виводу", err)
            }
        }
    }

    /** Скільки кадрів (семплів моно) уже передано в AudioTrack — щоб при
     *  завершенні дочекатися, поки він їх справді програє. */
    private var framesWritten = 0L

    fun write(bytes: ByteArray) {
        val h = handler ?: return
        h.post {
            val track = audioTrack ?: return@post
            try {
                val written = track.write(bytes, 0, bytes.size)
                if (written > 0) framesWritten += written / 2 // PCM16 моно
            } catch (err: Throwable) {
                Log.e(TAG, "Помилка запису в AudioTrack", err)
            }
        }
    }

    /**
     * Зупинити плеєр.
     *
     * [drain] = false (кнопка «Зупинити», аварійне завершення): скидаємо ВСІ
     * ще не виконані write() — інакше quitSafely() чекає, поки серіалізована
     * черга дограє геть усю накопичену репліку (могло бути кілька секунд), і
     * кнопка реагує з відчутною затримкою; AudioTrack звільняється одразу.
     *
     * [drain] = true (природний кінець квесту): навпаки, даємо ДОГРАТИ все,
     * що вже передано, — черга write() виконується до кінця, а AudioTrack
     * звільняється лише коли його головка відтворення дійшла до останнього
     * записаного кадру (з обмеженням [DRAIN_TIMEOUT_MS]). Без цього кінець
     * фінальної репліки персонажа обрізався: Dart вважав, що все програно
     * (за тривалістю переданих байтів), а в буфері AudioTrack і на
     * Bluetooth-шляху ще лишалась частка секунди звуку.
     */
    fun stop(drain: Boolean = false) {
        val h = handler ?: return
        val t = thread
        if (!drain) h.removeCallbacksAndMessages(null)
        h.post { releaseTrack(drain) }
        t?.quitSafely()
        thread = null
        handler = null
    }

    private fun releaseTrack(drain: Boolean) {
        try {
            audioTrack?.let {
                if (drain) waitPlayedOut(it)
                it.stop()
                it.release()
            }
        } catch (err: Throwable) {
            Log.e(TAG, "Помилка зупинки AudioTrack", err)
        } finally {
            audioTrack = null
            framesWritten = 0L
        }
    }

    /** Дочекатися, поки AudioTrack програє все записане (або тайм-аут). */
    private fun waitPlayedOut(track: AudioTrack) {
        val target = framesWritten
        if (target <= 0L) return
        val deadline = System.currentTimeMillis() + DRAIN_TIMEOUT_MS
        try {
            // playbackHeadPosition — 32-бітний лічильник кадрів; для наших
            // реплік (хвилини, не години) переповнення не загрожує.
            while (System.currentTimeMillis() < deadline) {
                val head = track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
                if (head >= target) break
                Thread.sleep(20)
            }
            // Запас на шлях від AudioTrack до динаміка/Bluetooth: головка
            // рахує кадри, віддані міксеру, а не вже почуті.
            Thread.sleep(TAIL_LATENCY_MS)
        } catch (_: Throwable) {
            // Не змогли дочекатись — зупиняємо як є.
        }
    }

    companion object {
        private const val TAG = "PcmAudioPlayer"

        /** Максимум чекати, поки AudioTrack дограє записане, при stop(drain). */
        private const val DRAIN_TIMEOUT_MS = 4_000L

        /** Запас після останнього кадру — затримка виводу (Bluetooth до ~300 мс). */
        private const val TAIL_LATENCY_MS = 400L
    }
}
