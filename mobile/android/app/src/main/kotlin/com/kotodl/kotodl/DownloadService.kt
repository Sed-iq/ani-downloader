package com.kotodl.kotodl

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps the process (and the Dart download loop in it) running while the app is in the
 * background or the screen is off. It downloads nothing itself; it holds a wake lock
 * and shows progress.
 */
class DownloadService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = build(this, intent?.getStringExtra(EXTRA_TEXT) ?: "", null, true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(ID, notification)
        }
        if (wakeLock == null) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "kotodl:download").apply {
                setReferenceCounted(false)
                acquire(6 * 60 * 60 * 1000L) // a whole season at worst; released when the batch ends
            }
        }
        return START_NOT_STICKY // a restarted service would have no download to keep alive
    }

    override fun onDestroy() {
        wakeLock?.release()
        wakeLock = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "downloads"
        private const val ID = 1
        private const val DONE_ID = 2
        private const val EXTRA_TEXT = "text"

        fun start(context: Context, text: String) {
            val intent = Intent(context, DownloadService::class.java).putExtra(EXTRA_TEXT, text)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** Posts straight to the notification: starting the service again from the background isn't allowed. */
        fun update(context: Context, text: String, progress: Int?) {
            manager(context).notify(ID, build(context, text, progress, true))
        }

        fun stop(context: Context, text: String?) {
            context.stopService(Intent(context, DownloadService::class.java))
            if (text != null) manager(context).notify(DONE_ID, build(context, text, null, false))
        }

        private fun manager(context: Context) =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        private fun build(context: Context, text: String, progress: Int?, ongoing: Boolean): Notification {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager(context).createNotificationChannel(
                    NotificationChannel(CHANNEL, "Downloads", NotificationManager.IMPORTANCE_LOW)
                )
            }
            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            @Suppress("DEPRECATION")
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL)
            } else {
                Notification.Builder(context)
            }
            builder
                .setSmallIcon(if (ongoing) android.R.drawable.stat_sys_download else android.R.drawable.stat_sys_download_done)
                .setContentTitle("Anikoto Downloader")
                .setContentText(text)
                .setContentIntent(open)
                .setOngoing(ongoing)
                .setOnlyAlertOnce(true)
                .setAutoCancel(!ongoing)
            if (progress != null) builder.setProgress(1000, progress, false)
            return builder.build()
        }
    }
}
