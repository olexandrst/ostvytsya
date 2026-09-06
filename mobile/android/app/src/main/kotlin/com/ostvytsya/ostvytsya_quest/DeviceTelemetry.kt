package com.ostvytsya.ostvytsya_quest

import android.Manifest
import android.app.ActivityManager
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.BatteryManager
import android.os.Build
import android.os.CancellationSignal
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.Process
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

    /** Остання відома точка, старша за це, — привід замовити нове визначення. */
    private const val MAX_LOCATION_AGE_MS = 15L * 60L * 1000L

    /** Скільки чекати на нове визначення координат, перш ніж звітувати без них. */
    private const val LOCATION_TIMEOUT_MS = 15_000L

    /**
     * Дані для звіту з координатами «за можливості свіжими»: спершу остання
     * відома точка; якщо її немає або вона старша за [MAX_LOCATION_AGE_MS] —
     * одноразовий запит нового визначення з тайм-аутом. Термінал у парку
     * стоїть на місці, і без жодного застосунку з картами «останньої відомої»
     * точки в системі може просто не бути — тоді панель ніколи не показала б
     * координат. Виклик [callback] — рівно один, на головному потоці.
     */
    fun collectAsync(context: Context, callback: (Map<String, Any?>) -> Unit) {
        val base = collect(context)
        val last = lastLocation(context)
        val freshEnough = last != null &&
            System.currentTimeMillis() - last.time <= MAX_LOCATION_AGE_MS
        if (freshEnough || !hasLocationPermission(context)) {
            callback(base)
            return
        }
        requestCurrentLocation(context) { located ->
            val chosen = located ?: last
            callback(
                base + mapOf(
                    "latitude" to chosen?.latitude,
                    "longitude" to chosen?.longitude
                )
            )
        }
    }

    fun collect(context: Context): Map<String, Any?> {
        val location = lastLocation(context)
        return mapOf(
            "device_model" to deviceModel(),
            "battery_percent" to batteryPercent(context),
            "phone_number" to phoneNumber(context),
            "bluetooth" to bluetoothDevices(context),
            "latitude" to location?.latitude,
            "longitude" to location?.longitude,
            "memory" to memory(context)
        )
    }

    /**
     * Пам'ять процесу (PSS, нативна купа, Java-купа) і пристрою (вільно /
     * усього, чи система вже в режимі нестачі). Усе в МБ. Для журналу сесії:
     * коли застосунок убиває LOW_MEMORY, ці цифри показують, чи росте саме
     * наш процес від сесії до сесії (витік), чи пристрій загалом на межі.
     */
    fun memory(context: Context): Map<String, Any?> = try {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo()
        am.getMemoryInfo(info)
        val pss = am.getProcessMemoryInfo(intArrayOf(Process.myPid())).firstOrNull()
        val runtime = Runtime.getRuntime()
        val mb = 1024L * 1024L
        mapOf(
            "process_pss_mb" to (pss?.totalPss ?: 0) / 1024, // totalPss — у КБ
            "native_heap_mb" to Debug.getNativeHeapAllocatedSize() / mb,
            "java_heap_mb" to (runtime.totalMemory() - runtime.freeMemory()) / mb,
            "device_avail_mb" to info.availMem / mb,
            "device_total_mb" to info.totalMem / mb,
            "device_threshold_mb" to info.threshold / mb,
            "device_low_memory" to info.lowMemory
        )
    } catch (err: Throwable) {
        Log.w(TAG, "Знімок пам'яті недоступний", err)
        emptyMap()
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

    private fun hasLocationPermission(context: Context): Boolean =
        hasPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ||
            hasPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION)

    /**
     * Одноразове нове визначення координат із тайм-аутом. Провайдер: fused
     * (Android 12+), інакше мережевий — вони дають точку за секунди навіть у
     * приміщенні; GPS — лише якщо інших немає (холодний старт може тривати
     * довше за тайм-аут). Колбек — рівно один раз, на головному потоці.
     */
    private fun requestCurrentLocation(context: Context, callback: (Location?) -> Unit) {
        val handler = Handler(Looper.getMainLooper())
        var done = false
        fun finish(location: Location?) {
            if (done) return
            done = true
            handler.post { callback(location) }
        }
        try {
            val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
            val candidates = buildList {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) add(LocationManager.FUSED_PROVIDER)
                add(LocationManager.NETWORK_PROVIDER)
                add(LocationManager.GPS_PROVIDER)
            }
            val provider = candidates.firstOrNull { p ->
                try { lm.isProviderEnabled(p) } catch (_: Throwable) { false }
            }
            if (provider == null) {
                finish(null)
                return
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val signal = CancellationSignal()
                handler.postDelayed({
                    if (!done) {
                        signal.cancel()
                        finish(null)
                    }
                }, LOCATION_TIMEOUT_MS)
                lm.getCurrentLocation(provider, signal, context.mainExecutor) { location ->
                    finish(location)
                }
            } else {
                val listener = object : LocationListener {
                    override fun onLocationChanged(location: Location) = finish(location)
                }
                @Suppress("DEPRECATION")
                lm.requestSingleUpdate(provider, listener, Looper.getMainLooper())
                handler.postDelayed({
                    if (!done) {
                        try { lm.removeUpdates(listener) } catch (_: Throwable) {}
                        finish(null)
                    }
                }, LOCATION_TIMEOUT_MS)
            }
        } catch (err: Throwable) {
            Log.w(TAG, "Нове визначення координат не вдалося", err)
            finish(null)
        }
    }

    /**
     * Останні відомі координати (дешево й миттєво). Свіже визначення, якщо
     * ця точка стара чи її немає, замовляє [collectAsync].
     */
    private fun lastLocation(context: Context): Location? {
        if (!hasLocationPermission(context)) return null
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
