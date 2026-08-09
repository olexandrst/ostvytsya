package com.ostvytsya.ostvytsya_quest

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Місток Dart ⇄ Android для двох речей, які потребують нативного коду:
 *   1) foreground-сервіс + wake lock, щоб квест не зупинявся з вимкненим
 *      екраном (QuestForegroundService);
 *   2) запит на виняток з оптимізації батареї — без цього система рано чи
 *      пізно приспить застосунок навіть із активним foreground-сервісом.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "com.ostvytsya.ostvytsya_quest/foreground"
    private val TAG = "MainActivity"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
}
