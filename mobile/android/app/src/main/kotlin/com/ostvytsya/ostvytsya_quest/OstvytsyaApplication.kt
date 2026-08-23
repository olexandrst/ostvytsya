package com.ostvytsya.ostvytsya_quest

import android.app.Application
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.system.exitProcess

/**
 * Записує будь-який необроблений виняток (включно з нативними падіннями на
 * рівні Kotlin/Java — не C++) у файл перед тим, як процес завершиться.
 * Потрібно, бо на реальному пристрої без adb користувач інакше не бачить
 * ЖОДНОГО сліду краху. MainActivity читає цей файл при наступному запуску
 * й показує його в застосунку — скопіювати/переслати можна прямо з екрана.
 */
class OstvytsyaApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                writeCrashLog(throwable)
            } catch (_: Throwable) {
                // Не даємо запису журналу самому стати причиною ще одного краху.
            }
            if (previousHandler != null) {
                previousHandler.uncaughtException(thread, throwable)
            } else {
                android.os.Process.killProcess(android.os.Process.myPid())
                exitProcess(10)
            }
        }
    }

    private fun writeCrashLog(throwable: Throwable) {
        val sw = StringWriter()
        throwable.printStackTrace(PrintWriter(sw))
        val timestamp = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())
        File(filesDir, CRASH_LOG_FILE).writeText("Час: $timestamp\n\n$sw")
    }

    companion object {
        const val CRASH_LOG_FILE = "last_crash.txt"
    }
}
