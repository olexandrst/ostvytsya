package com.ostvytsya.ostvytsya_quest

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Утримує процес застосунку "живим" і активним, поки триває квест — навіть
 * коли екран вимкнено. Сама бізнес-логіка (WebSocket-и до Gemini/OpenAI,
 * мікрофон, відтворення) лишається в звичайному Flutter-двигуні того самого
 * процесу; цей сервіс лише:
 *   1) переводить процес у стан foreground-сервісу (через постійне
 *      сповіщення) — це захищає його від "заморозки" системою;
 *   2) тримає PARTIAL_WAKE_LOCK — CPU не засинає, навіть коли дисплей вимкнено.
 *
 * Навмисно НЕ утримує екран увімкненим (на відміну від пакета wakelock_plus,
 * чий enable() саме для цього призначений) — вимкнений екран є основним,
 * очікуваним режимом роботи.
 */
class QuestForegroundService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            startForegroundWithNotification()
            acquireWakeLock()
        } catch (t: Throwable) {
            // Не даємо збою тут звалити весь процес (той самий процес, що й
            // Flutter-двигун) — квест лишиться без сповіщення/wake lock, але
            // застосунок не впаде.
            Log.e(TAG, "Не вдалося підняти foreground-сервіс", t)
            stopSelf()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "ostvytsya:quest_wakelock"
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    private fun startForegroundWithNotification() {
        val channelId = "quest_running"
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Активний квест",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Сповіщення показується, поки триває голосовий квест."
            }
            manager?.createNotificationChannel(channel)
        }

        val openIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val notification: Notification = NotificationCompat.Builder(this, channelId)
            .setContentTitle("Оствиця — квест триває")
            .setContentText("Персонаж слухає й говорить. Екран можна вимкнути.")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setContentIntent(contentIntent)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        private const val TAG = "QuestForegroundService"
        private const val NOTIFICATION_ID = 4271
    }
}
