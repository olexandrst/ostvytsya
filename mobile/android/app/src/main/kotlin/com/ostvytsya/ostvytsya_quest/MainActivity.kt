package com.ostvytsya.ostvytsya_quest

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.content.Intent
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Місток Dart ⇄ Android для двох речей, які потребують нативного коду:
 *   1) foreground-сервіс + wake lock, щоб квест не зупинявся з вимкненим
 *      екраном (QuestForegroundService);
 *   2) запит на виняток з оптимізації батареї — без цього система рано чи
 *      пізно приспить застосунок навіть із активним foreground-сервісом.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "com.ostvytsya.ostvytsya_quest/foreground"
    private val audioDevicesChannelName = "com.ostvytsya.ostvytsya_quest/audio_devices"
    private val TAG = "MainActivity"
    private val pcmPlayer = PcmAudioPlayer()
    private var audioDeviceCallback: AudioDeviceCallback? = null
    private var audioDeviceEventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, audioDevicesChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    audioDeviceEventSink = events
                    registerAudioDeviceCallback()
                }

                override fun onCancel(arguments: Any?) {
                    unregisterAudioDeviceCallback()
                    audioDeviceEventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            // Жодна з цих дій не має права звалити застосунок — краще
            // повернути помилку в Dart, ніж упустити виняток нативного коду
            // й обірвати весь (спільний з Flutter-двигуном) процес.
            try {
                when (call.method) {
                    "startService" -> {
                        startQuestForegroundService(Intent(this, QuestForegroundService::class.java))
                        result.success(null)
                    }
                    "stopService" -> {
                        stopService(Intent(this, QuestForegroundService::class.java))
                        result.success(null)
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        val pm = getSystemService(POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        val intent = Intent(
                            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                            Uri.parse("package:$packageName")
                        )
                        startActivity(intent)
                        result.success(null)
                    }
                    "getLastCrashLog" -> {
                        val file = File(filesDir, OstvytsyaApplication.CRASH_LOG_FILE)
                        result.success(if (file.exists()) file.readText() else null)
                    }
                    "clearLastCrashLog" -> {
                        File(filesDir, OstvytsyaApplication.CRASH_LOG_FILE).delete()
                        result.success(null)
                    }
                    "getLastExitReason" -> {
                        result.success(lastExitReasonText())
                    }
                    "acknowledgeExitReason" -> {
                        acknowledgeExitReason()
                        result.success(null)
                    }
                    "pcmPlayerStart" -> {
                        val sampleRate = (call.argument<Int>("sampleRate")) ?: 24000
                        pcmPlayer.start(sampleRate)
                        result.success(null)
                    }
                    "pcmPlayerWrite" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        if (bytes != null) pcmPlayer.write(bytes)
                        result.success(null)
                    }
                    "pcmPlayerStop" -> {
                        pcmPlayer.stop()
                        result.success(null)
                    }
                    "pcmPlayerSetOutputDevice" -> {
                        val deviceId = call.argument<Int>("deviceId")
                        pcmPlayer.setPreferredDevice(applicationContext, deviceId)
                        result.success(null)
                    }
                    "listAudioDevices" -> {
                        val direction = call.argument<String>("direction") ?: "input"
                        result.success(AudioDeviceUtils.listDevices(applicationContext, direction))
                    }
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                Log.e(TAG, "Помилка методу '${call.method}'", t)
                result.error("NATIVE_ERROR", t.message, null)
            }
        }
    }

    private fun startQuestForegroundService(intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    /**
     * Слухаємо під'єднання/від'єднання аудіо-пристроїв (навушники, USB,
     * Bluetooth), щоб Dart-бік міг переобрати найкращий доступний пристрій
     * без переривання квесту (requirement: автоперемикання при відключенні).
     * Самі деталі пристрою Dart не потребує тут — просто перечитує список
     * через listAudioDevices при кожній події.
     */
    private fun registerAudioDeviceCallback() {
        if (audioDeviceCallback != null || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val cb = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
                audioDeviceEventSink?.success("changed")
            }

            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                audioDeviceEventSink?.success("changed")
            }
        }
        audioDeviceCallback = cb
        am.registerAudioDeviceCallback(cb, null)
    }

    private fun unregisterAudioDeviceCallback() {
        val cb = audioDeviceCallback ?: return
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        am.unregisterAudioDeviceCallback(cb)
        audioDeviceCallback = null
    }

    /**
     * Причина останнього завершення процесу від самої системи — це працює
     * навіть для СПРАВЖНІХ нативних падінь (SIGSEGV у бібліотеці типу
     * flutter_sound), які Thread.setDefaultUncaughtExceptionHandler у
     * OstvytsyaApplication не бачить, бо це не Java-виняток. Доступно з
     * Android 11 (API 30). Показує лише НОВУ причину — не старішу за ту,
     * що вже підтверджена через acknowledgeExitReason().
     */
    private fun lastExitReasonText(): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val infos = am.getHistoricalProcessExitReasons(packageName, 0, 5)
        if (infos.isEmpty()) return null
        val info = infos[0]
        val lastAck = prefs().getLong(PREF_LAST_ACK_TS, 0L)
        if (info.timestamp <= lastAck) return null

        val sb = StringBuilder()
        sb.append("Причина завершення: ${reasonName(info.reason)} (код ${info.reason})\n")
        sb.append("Опис: ${info.description}\n")
        sb.append("Час: ${SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date(info.timestamp))}\n")
        try {
            info.traceInputStream?.use { stream ->
                val trace = stream.bufferedReader().readText()
                if (trace.isNotBlank()) {
                    sb.append("\n--- Трасування ---\n").append(trace.take(8000))
                }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "Не вдалося прочитати трасування виходу", t)
        }
        return sb.toString()
    }

    private fun acknowledgeExitReason() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val infos = am.getHistoricalProcessExitReasons(packageName, 0, 1)
        val ts = infos.firstOrNull()?.timestamp ?: return
        prefs().edit().putLong(PREF_LAST_ACK_TS, ts).apply()
    }

    private fun prefs() = getSharedPreferences("ostvytsya_diagnostics", MODE_PRIVATE)

    private fun reasonName(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_CRASH -> "CRASH (виняток у Java/Kotlin коді)"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE (нативний збій, напр. у бібліотеці)"
        ApplicationExitInfo.REASON_ANR -> "ANR (застосунок не відповідав)"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
        ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
        ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
        ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
        else -> "код=$reason"
    }

    companion object {
        private const val PREF_LAST_ACK_TS = "last_ack_exit_ts"
    }
}
