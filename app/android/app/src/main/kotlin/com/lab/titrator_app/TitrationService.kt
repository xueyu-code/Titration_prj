package com.lab.titrator_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Foreground service that keeps the process running while a titration is in
 * progress, so the app can still watch the pH, stop the device and notify the
 * user with the screen off or the app in the background. It does no work
 * itself; its notification is the only visible part.
 */
class TitrationService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                getString(R.string.titration_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
        val open = PendingIntent.getActivity(
            this,
            0,
            packageManager.getLaunchIntentForPackage(packageName)!!,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(intent?.getStringExtra(EXTRA_TITLE))
            .setContentText(intent?.getStringExtra(EXTRA_TEXT))
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
        try {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } catch (e: RuntimeException) {
            // Not allowed to run in the foreground (e.g. the Bluetooth
            // permission was revoked). The titration works without it.
            stopSelf()
        }
        return START_NOT_STICKY
    }

    companion object {
        private const val CHANNEL_ID = "titration_running"
        private const val NOTIFICATION_ID = 2
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"

        /** Starts the service, or updates its notification if it already runs. */
        fun start(context: Context, title: String?, text: String?) {
            ContextCompat.startForegroundService(
                context,
                Intent(context, TitrationService::class.java)
                    .putExtra(EXTRA_TITLE, title)
                    .putExtra(EXTRA_TEXT, text),
            )
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, TitrationService::class.java))
        }
    }
}
