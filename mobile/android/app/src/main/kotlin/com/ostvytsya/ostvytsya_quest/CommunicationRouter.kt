package com.ostvytsya.ostvytsya_quest

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.util.Log

/**
 * Голосовий канал Bluetooth-гарнітури (SCO) на час УСЬОГО квесту.
 *
 * Чому цим керуємо ми, а не плагін `record` (у якого є власний
 * manageBluetooth): плагін піднімає й перевіряє SCO лише коли СТАРТУЄ
 * запис. А в нас напівдуплекс — мікрофон апаратно вимкнено саме тоді, коли
 * говорить персонаж. Виходило, що станом каналу розпоряджається мікрофон, а
 * від цього стану залежить, куди піде голос персонажа: поки SCO піднято,
 * профіль A2DP призупинений, і медіа-потік у гарнітуру не потрапляє, а поки
 * SCO опущено — навпаки, не потрапляє голос розмови.
 *
 * Через це два «господарі» одного каналу неминуче розходились: перемкнеш
 * пристрій, поки персонаж говорить, — і режим відтворення вже не відповідає
 * реальному стану SCO, тобто тиша. Тепер канал тримає рівно один господар
 * (ми), незалежно від того, чи працює зараз мікрофон, а `record` до нього
 * не торкається взагалі (manageBluetooth: false).
 */
object CommunicationRouter {
    private const val TAG = "CommunicationRouter"

    private var active = false
    private var previousMode = AudioManager.MODE_NORMAL

    private fun audioManager(context: Context): AudioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private fun isBluetoothType(type: Int): Boolean =
        type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
            type == AudioDeviceInfo.TYPE_BLE_HEADSET

    /** Підняти SCO. true — якщо канал справді перемкнено на гарнітуру. */
    fun start(context: Context): Boolean {
        if (active) return true
        val am = audioManager(context)
        return try {
            val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val target = am.availableCommunicationDevices.firstOrNull {
                    isBluetoothType(it.type)
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
            Log.e(TAG, "Не вдалося увімкнути голосовий канал гарнітури", err)
            false
        }
    }

    /** Повернути звичайну маршрутизацію. */
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
            Log.e(TAG, "Не вдалося вимкнути голосовий канал гарнітури", err)
        }
    }
}
