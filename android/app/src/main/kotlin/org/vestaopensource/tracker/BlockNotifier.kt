package org.vestaopensource.tracker

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock

/**
 * Notice on the minor's own phone when an app is blocked, with the
 * option to ask the guardian for permission. Tapping it opens Vesta Tracker
 * with the request already filled in (see MainActivity.EXTRA_REQUEST_PACKAGE).
 */
object BlockNotifier {
    private const val CHANNEL_ID = "vesta_tracker_blocks"
    private const val THROTTLE_MS = 60_000L
    private val lastShown = HashMap<String, Long>()

    enum class Reason(private val es: String, private val en: String, val requestType: String) {
        BLOCKED("está bloqueada por tu tutor", "is blocked by your guardian", "unlock_app"),
        STUDY("no está disponible en modo estudio", "is not available in study mode", "unlock_app"),
        LIMIT("ya usó todo su tiempo de hoy", "has used up all its time for today", "extra_time");

        val label: String get() = Lang.t(es, en)
    }

    fun show(context: Context, packageName: String, reason: Reason) {
        val now = SystemClock.elapsedRealtime()
        synchronized(lastShown) {
            val previous = lastShown[packageName] ?: 0L
            if (now - previous < THROTTLE_MS) return
            lastShown[packageName] = now
        }

        val label = try {
            val info = context.packageManager.getApplicationInfo(packageName, 0)
            context.packageManager.getApplicationLabel(info).toString()
        } catch (_: PackageManager.NameNotFoundException) {
            packageName
        }

        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE)
            as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
            !manager.areNotificationsEnabled()
        ) return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    Lang.t("Apps bloqueadas", "Blocked apps"),
                    NotificationManager.IMPORTANCE_DEFAULT
                ).apply { description = Lang.t("Avisos cuando Vesta bloquea una aplicación", "Notices when Vesta blocks an app") }
            )
        }

        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(MainActivity.EXTRA_REQUEST_PACKAGE, packageName)
            putExtra(MainActivity.EXTRA_REQUEST_APP_NAME, label)
            putExtra(MainActivity.EXTRA_REQUEST_TYPE, reason.requestType)
        }
        val pending = PendingIntent.getActivity(
            context,
            packageName.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }

        val notification = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("$label ${reason.label}")
            .setContentText(Lang.t("Toca para pedir permiso a tu tutor.", "Tap to ask your guardian for permission."))
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()

        try {
            manager.notify(packageName.hashCode(), notification)
        } catch (_: SecurityException) {
            // No notification permission (Android 13+): the notice is skipped.
        }
    }
}
