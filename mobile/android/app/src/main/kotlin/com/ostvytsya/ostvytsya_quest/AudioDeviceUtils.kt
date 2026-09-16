package com.ostvytsya.ostvytsya_quest

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaRecorder
import android.os.Build

/**
 * Перелік і класифікація аудіо-пристроїв входу/виходу для вибору в
 * налаштуваннях і автопріоритету (провідний → bluetooth → вбудований).
 * Потребує API 23+ (AudioDeviceInfo/AudioManager.getDevices) — на старіших
 * версіях список порожній, і застосунок просто працює на пристрої за
 * замовчуванням, як і раніше.
 */
object AudioDeviceUtils {
    private const val DIRECTION_OUTPUT = "output"

    fun listDevices(context: Context, direction: String): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return emptyList()
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val isOutput = direction == DIRECTION_OUTPUT
        val flag = if (isOutput) AudioManager.GET_DEVICES_OUTPUTS else AudioManager.GET_DEVICES_INPUTS
        return am.getDevices(flag)
            .filter { isRelevant(it.type, isOutput) }
            .map { deviceToMap(it) }
    }

    fun findDevice(context: Context, direction: String, id: Int): AudioDeviceInfo? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val flag = if (direction == DIRECTION_OUTPUT) AudioManager.GET_DEVICES_OUTPUTS else AudioManager.GET_DEVICES_INPUTS
        return am.getDevices(flag).firstOrNull { it.id == id }
    }

    /**
     * СПРАВЖНІЙ стан маршрутизації звуку — для журналу сесії.
     *
     * Назва обраного пристрою в діагностиці («Слухаю мікрофон «Jabra…»») —
     * це лише намір: плагін запису міг не підняти голосовий канал Bluetooth,
     * і тоді AudioRecord тихо пише з вбудованого мікрофона телефона, а назва
     * в журналі та сама. Тут — те, що система робить насправді:
     *   • активні записи ЦЬОГО застосунку (AudioManager.getActiveRecordingConfigurations):
     *     з якого пристрою йде запис, яке джерело, частота на клієнті й на
     *     пристрої (8000 на пристрої = вузькосмуговий SCO-канал CVSD, 16000 =
     *     широкосмуговий mSBC);
     *   • пристрій розмови (Android 12+, setCommunicationDevice) і режим
     *     AudioManager;
     *   • стан SCO за старим API (isBluetoothScoOn) — на Android 12+ він може
     *     бути false навіть коли маршрут через пристрій розмови працює.
     */
    fun routeState(context: Context): Map<String, Any?> {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val comm: AudioDeviceInfo? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) am.communicationDevice else null
        val recordings: List<Map<String, Any?>> =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                try {
                    am.activeRecordingConfigurations.map { cfg ->
                        val dev = cfg.audioDevice
                        mapOf(
                            "source" to sourceLabel(cfg.clientAudioSource),
                            "device" to dev?.let { deviceLabel(it) },
                            "bucket" to dev?.let { bucketFor(it.type) },
                            "clientSampleRate" to cfg.clientFormat?.sampleRate,
                            "deviceSampleRate" to cfg.format?.sampleRate
                        )
                    }
                } catch (_: Throwable) {
                    emptyList()
                }
            } else {
                emptyList()
            }
        @Suppress("DEPRECATION")
        val scoOn = try { am.isBluetoothScoOn } catch (_: Throwable) { false }
        return mapOf(
            "mode" to modeLabel(am.mode),
            "scoOn" to scoOn,
            "commDevice" to comm?.let { deviceLabel(it) },
            "commBucket" to comm?.let { bucketFor(it.type) },
            "recordings" to recordings
        )
    }

    private fun sourceLabel(source: Int): String = when (source) {
        MediaRecorder.AudioSource.DEFAULT -> "default"
        MediaRecorder.AudioSource.MIC -> "mic"
        MediaRecorder.AudioSource.VOICE_RECOGNITION -> "voice_recognition"
        MediaRecorder.AudioSource.VOICE_COMMUNICATION -> "voice_communication"
        MediaRecorder.AudioSource.CAMCORDER -> "camcorder"
        MediaRecorder.AudioSource.UNPROCESSED -> "unprocessed"
        else -> "source_$source"
    }

    private fun modeLabel(mode: Int): String = when (mode) {
        AudioManager.MODE_NORMAL -> "normal"
        AudioManager.MODE_RINGTONE -> "ringtone"
        AudioManager.MODE_IN_CALL -> "in_call"
        AudioManager.MODE_IN_COMMUNICATION -> "in_communication"
        else -> "mode_$mode"
    }

    /** "wired" | "bluetooth" | "builtin" | "other" — для сортування за пріоритетом. */
    fun bucketFor(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
        AudioDeviceInfo.TYPE_BUILTIN_MIC -> "builtin"

        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_ACCESSORY,
        AudioDeviceInfo.TYPE_LINE_ANALOG,
        AudioDeviceInfo.TYPE_LINE_DIGITAL,
        AudioDeviceInfo.TYPE_DOCK -> "wired"

        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_HEARING_AID,
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BLE_SPEAKER -> "bluetooth"

        else -> "other"
    }

    private fun isRelevant(type: Int, isOutput: Boolean): Boolean {
        val bucket = bucketFor(type)
        if (bucket == "other") return false
        if (isOutput && type == AudioDeviceInfo.TYPE_BUILTIN_MIC) return false
        // Розмовний динамік (для дзвінків "до вуха") — набагато тихший за
        // основний гучномовець і взагалі не для цього застосунку. Якщо його
        // не виключити, телефони, що показують speaker+earpiece як два
        // окремих builtin-виходи, ламали правило "не чіпати маршрутизацію,
        // якщо пристрій лише один" (формально їх два) — автопідбір міг
        // причепитись саме до тихого розмовного динаміка.
        if (isOutput && type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE) return false
        if (!isOutput &&
            (type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER || type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE)
        ) return false
        return true
    }

    private fun deviceToMap(device: AudioDeviceInfo): Map<String, Any?> = mapOf(
        "id" to device.id,
        "label" to deviceLabel(device),
        "bucket" to bucketFor(device.type)
    )

    private fun deviceLabel(device: AudioDeviceInfo): String {
        val name = device.productName?.toString()
        return if (!name.isNullOrBlank() && name != "unknown") name else typeLabel(device.type)
    }

    private fun typeLabel(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "Вбудований динамік"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "Вбудований динамік (розмовний)"
        AudioDeviceInfo.TYPE_BUILTIN_MIC -> "Вбудований мікрофон"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "Дротова гарнітура"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "Дротові навушники"
        AudioDeviceInfo.TYPE_USB_HEADSET -> "USB-гарнітура"
        AudioDeviceInfo.TYPE_USB_DEVICE -> "USB-пристрій"
        AudioDeviceInfo.TYPE_USB_ACCESSORY -> "USB-аксесуар"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "Bluetooth (голос)"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "Bluetooth (аудіо)"
        AudioDeviceInfo.TYPE_HEARING_AID -> "Слуховий апарат"
        AudioDeviceInfo.TYPE_LINE_ANALOG -> "Лінійний вхід/вихід"
        AudioDeviceInfo.TYPE_DOCK -> "Док-станція"
        else -> "Аудіо-пристрій"
    }
}
