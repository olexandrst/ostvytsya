package com.ostvytsya.ostvytsya_quest

import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.util.Log

/**
 * Увімкнення мікрофона Bluetooth-гарнітури.
 *
 * Навіщо це окремо: мікрофон Bluetooth-гарнітури фізично працює ЛИШЕ через
 * профіль SCO/HFP (той самий, яким іде голос у телефонній розмові). Android
 * не піднімає SCO сам собою — застосунок мусить його попросити явно. Якщо
 * цього не зробити, `AudioRecord`, прив'язаний до Bluetooth-мікрофона,
 * успішно відкривається й віддає… суцільну тишу, без жодної помилки. Саме
 * тому Vosk не показував навіть часткового розпізнавання, коли гарнітура
 * була під'єднана від початку квесту: він отримував самі нулі.
 *
 * Вмикаємо SCO ТІЛЬКИ якщо обраний ВХІД — Bluetooth. Для звичайної
 * Bluetooth-колонки (лише A2DP, мікрофона немає) робити цього не можна:
 * SCO глушить A2DP і перемикає звук на вузькосмуговий «телефонний» тракт,
 * тобто зіпсувало б відтворення голосу персонажа ні за що.
 */
object CommunicationRouter {
    private const val TAG = "CommunicationRouter"

    private var active = false
    private var previousMode = AudioManager.MODE_NORMAL

    private fun audioManager(context: Context): AudioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    /** Чи є пристрій із таким id Bluetooth-мікрофоном (потребує SCO). */
    fun isBluetoothInput(context: Context, deviceId: Int): Boolean {
        val info = AudioDeviceUtils.findDevice(context, "input", deviceId) ?: return false
        return AudioDeviceUtils.bucketFor(info.type) == "bluetooth"
    }

    /**
     * Підняти SCO для Bluetooth-мікрофона. Повертає true, якщо маршрут
     * справді перемкнено (тоді перед стартом запису варто дати лінку
     * секунду-другу на встановлення).
     */
    fun start(context: Context, deviceId: Int): Boolean {
        if (!isBluetoothInput(context, deviceId)) return false
        val am = audioManager(context)
        return try {
            val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // З Android 12 SCO піднімається саме так; список
                // availableCommunicationDevices містить ВИХІДНІ пристрої,
                // придатні для розмови, — саме їх очікує setCommunicationDevice.
                val target = am.availableCommunicationDevices.firstOrNull {
                    AudioDeviceUtils.bucketFor(it.type) == "bluetooth"
                }
                if (target == null) false else am.setCommunicationDevice(target)
            } else {
                previousMode = am.mode
                @Suppress("DEPRECATION")
                am.mode = AudioManager.MODE_IN_COMMUNICATION
                @Suppress("DEPRECATION")
                am.startBluetoothSco()
                @Suppress("DEPRECATION")
                am.setBluetoothScoOn(true)
                true
            }
            active = ok
            ok
        } catch (err: Throwable) {
            Log.e(TAG, "Не вдалося увімкнути Bluetooth-мікрофон (SCO)", err)
            false
        }
    }

    /** Повернути звичайну маршрутизацію (SCO більше не потрібен). */
    fun stop(context: Context) {
        if (!active) return
        active = false
        val am = audioManager(context)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                am.clearCommunicationDevice()
            } else {
                @Suppress("DEPRECATION")
                am.setBluetoothScoOn(false)
                @Suppress("DEPRECATION")
                am.stopBluetoothSco()
                @Suppress("DEPRECATION")
                am.mode = previousMode
            }
        } catch (err: Throwable) {
            Log.e(TAG, "Не вдалося вимкнути Bluetooth-мікрофон (SCO)", err)
        }
    }
}
