package com.ostvytsya.ostvytsya_quest

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.os.BatteryManager
import android.os.Build
import android.telephony.TelephonyManager
import android.util.Log

/**
 * Дані про пристрій для звіту в веб-панель.
 *
 * Усе тут — «за можливості»: кожне поле може бути null, і це нормальний,
 * очікуваний стан, а не помилка. Звіт про статус не повинен нічого вимагати
 * від користувача й тим паче нічого ламати, тож жоден збір не кидає винятків
 * назовні.
 */
object DeviceTelemetry {
    private const val TAG = "DeviceTelemetry"

    fun collect(context: Context): Map<String, Any?> {
        val location = lastLocation(context)
        return mapOf(
            "device_model" to deviceModel(),
            "battery_percent" to batteryPercent(context),
            "phone_number" to phoneNumber(context),
            "bluetooth" to bluetoothDevices(context),
            "latitude" to location?.latitude,
            "longitude" to location?.longitude
        )
    }

    /**
     * Перевірка дозволу через PackageManager, а не Context.checkSelfPermission:
     * друга з'явилась лише в API 23, і лінт справедливо чіплявся б до неї.
     */
    private fun hasPermission(context: Context, permission: String): Boolean =
        context.packageManager.checkPermission(permission, context.packageName) ==
            PackageManager.PERMISSION_GRANTED

    private fun deviceModel(): String {
        val maker = Build.MANUFACTURER?.replaceFirstChar { it.uppercase() } ?: ""
        val model = Build.MODEL ?: ""
        return if (model.startsWith(maker, ignoreCase = true)) model
        else listOf(maker, model).filter { it.isNotBlank() }.joinToString(" ")
    }

    private fun batteryPercent(context: Context): Int? = try {
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY).takeIf { it in 0..100 }
    } catch (err: Throwable) {
        Log.w(TAG, "Заряд батареї недоступний", err)
        null
    }

    /**
     * Власний номер телефону.
     *
     * ‼️ Чесно: Android віддає його ДАЛЕКО не завжди. Номер зберігається на
     * SIM-карті лише якщо його туди записав оператор, і в більшості випадків
     * (особливо в Україні) там порожньо. Потрібен ще й дозвіл
     * READ_PHONE_NUMBERS. Тож null тут — типовий результат, а не поламаний
     * збір; у панелі колонка просто лишиться порожньою.
     */
    private fun phoneNumber(context: Context): String? {
        val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Manifest.permission.READ_PHONE_NUMBERS
        } else {
            @Suppress("DEPRECATION")
            Manifest.permission.READ_PHONE_STATE
        }
        if (!hasPermission(context, permission)) return null
        return try {
            val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
            @Suppress("DEPRECATION")
            tm.line1Number?.takeIf { it.isNotBlank() }
        } catch (err: Throwable) {
            Log.w(TAG, "Номер телефону недоступний", err)
            null
        }
    }

    /**
     * Під'єднані Bluetooth-пристрої та їхній заряд.
     *
     * ‼️ Публічного API для заряду Bluetooth-пристрою в Android немає. Є
     * прихований метод BluetoothDevice.getBatteryLevel(), і ми обережно
     * пробуємо його через рефлексію — на багатьох прошивках (і на Android 11+
     * через обмеження прихованих API) він просто недоступний. Тоді пристрій
     * потрапляє у звіт без заряду: назву показати все одно корисно.
     */
    private fun bluetoothDevices(context: Context): List<Map<String, Any?>> {
        if (!hasPermission(context, Manifest.permission.BLUETOOTH_CONNECT)) {
            return emptyList()
        }
        return try {
            val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            val adapter: BluetoothAdapter = manager?.adapter ?: return emptyList()
            if (!adapter.isEnabled) return emptyList()

            // Проксі профілю (getConnectedDevices) приходить асинхронно, а звіт
            // має бути миттєвим — тож беремо звʼязані пристрої й питаємо в
            // кожного, чи він зараз під'єднаний.
            val connected = adapter.bondedDevices.orEmpty().filter { isConnected(it) }
            connected.map { device ->
                mapOf(
                    "name" to (device.name ?: device.address),
                    "battery" to batteryOf(device)
                )
            }
        } catch (err: Throwable) {
            Log.w(TAG, "Список Bluetooth-пристроїв недоступний", err)
            emptyList()
        }
    }

    private fun isConnected(device: BluetoothDevice): Boolean = try {
        val method = device.javaClass.getMethod("isConnected")
        method.invoke(device) as? Boolean ?: false
    } catch (_: Throwable) {
        false
    }

    private fun batteryOf(device: BluetoothDevice): Int? = try {
        val method = device.javaClass.getMethod("getBatteryLevel")
        val level = method.invoke(device) as? Int ?: -1
        level.takeIf { it in 0..100 }
    } catch (_: Throwable) {
        null
    }

    /**
     * Останні відомі координати. Навмисно НЕ замовляємо нове визначення: звіт
     * має бути дешевим і миттєвим, а для «де стоїть термінал у парку» точності
     * останньої відомої точки цілком достатньо.
     */
    private fun lastLocation(context: Context): Location? {
        val fine = hasPermission(context, Manifest.permission.ACCESS_FINE_LOCATION)
        val coarse = hasPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION)
        if (!fine && !coarse) return null
        return try {
            val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
            var best: Location? = null
            for (provider in lm.getProviders(true)) {
                val location = try {
                    lm.getLastKnownLocation(provider)
                } catch (_: SecurityException) {
                    null
                } ?: continue
                val current = best
                if (current == null || location.time > current.time) best = location
            }
            best
        } catch (err: Throwable) {
            Log.w(TAG, "Координати недоступні", err)
            null
        }
    }
}
