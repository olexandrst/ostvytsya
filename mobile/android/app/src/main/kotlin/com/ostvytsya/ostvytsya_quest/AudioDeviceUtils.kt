package com.ostvytsya.ostvytsya_quest

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
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
