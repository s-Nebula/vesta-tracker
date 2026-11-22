package org.vestaopensource.tracker

import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.os.SystemClock
import android.util.Log
import org.json.JSONObject
import java.util.Calendar

/**
 * Daily limits per app and temporary permissions granted by the guardian.
 *
 * * `flutter.app_limits_json`: {"package": minutesPerDay} (controls/app_limits).
 * * `flutter.temporary_allow_json`: {"package": untilMs} — requests from the
 *   minor approved by the guardian; while they are valid the app is not
 *   blocked by rules, study mode or daily limit.
 *
 * Today's usage is computed with UsageStatsManager ("Usage access"
 * permission, which the Tracker already requests for the reports).
 */
object AppTimePolicy {
    private const val TAG = "VestaAppTime"
    private const val LIMITS_KEY = "flutter.app_limits_json"
    private const val ALLOW_KEY = "flutter.temporary_allow_json"
    private const val USAGE_CACHE_MS = 30_000L

    @Volatile private var limitsJson: String? = null
    @Volatile private var limits: Map<String, Int> = emptyMap()
    @Volatile private var allowJson: String? = null
    @Volatile private var allowUntil: Map<String, Long> = emptyMap()

    private var usageCache: Map<String, Long> = emptyMap()
    private var usageCachedAt = 0L
    private var usageCacheDay = -1

    private fun parseMap(json: String?): Map<String, Long> {
        if (json.isNullOrBlank()) return emptyMap()
        return try {
            val data = JSONObject(json)
            data.keys().asSequence().associateWith { data.optLong(it, 0L) }
        } catch (e: Exception) {
            Log.e(TAG, "JSON no válido", e)
            emptyMap()
        }
    }

    private fun reload(context: Context) {
        val prefs = PrivacyLease.prefs(context)
        val newLimits = prefs.getString(LIMITS_KEY, null)
        if (newLimits != limitsJson) {
            limitsJson = newLimits
            limits = parseMap(newLimits)
                .mapValues { it.value.toInt() }
                .filterValues { it in 1..1440 }
        }
        val newAllow = prefs.getString(ALLOW_KEY, null)
        if (newAllow != allowJson) {
            allowJson = newAllow
            allowUntil = parseMap(newAllow)
        }
    }

    fun isTemporarilyAllowed(context: Context, packageName: String): Boolean {
        reload(context)
        return (allowUntil[packageName] ?: 0L) > System.currentTimeMillis()
    }

    fun limitMinutes(context: Context, packageName: String): Int? {
        reload(context)
        return limits[packageName]
    }

    /** Foreground milliseconds today (since 00:00) for each limited app. */
    fun usageToday(context: Context): Map<String, Long> {
        reload(context)
        val tracked = limits.keys
        if (tracked.isEmpty()) return emptyMap()

        val calendar = Calendar.getInstance()
        val day = calendar.get(Calendar.DAY_OF_YEAR)
        val nowElapsed = SystemClock.elapsedRealtime()
        if (day == usageCacheDay && nowElapsed - usageCachedAt < USAGE_CACHE_MS) {
            return usageCache
        }

        val now = System.currentTimeMillis()
        calendar.set(Calendar.HOUR_OF_DAY, 0)
        calendar.set(Calendar.MINUTE, 0)
        calendar.set(Calendar.SECOND, 0)
        calendar.set(Calendar.MILLISECOND, 0)
        val start = calendar.timeInMillis

        val totals = HashMap<String, Long>()
        try {
            val manager = context.getSystemService(Context.USAGE_STATS_SERVICE)
                as UsageStatsManager
            val events = manager.queryEvents(start, now)
            val resumedAt = HashMap<String, Long>()
            val event = UsageEvents.Event()

            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                val pkg = event.packageName ?: continue
                if (pkg !in tracked) continue

                when (event.eventType) {
                    UsageEvents.Event.ACTIVITY_RESUMED -> resumedAt[pkg] = event.timeStamp
                    UsageEvents.Event.ACTIVITY_PAUSED,
                    UsageEvents.Event.ACTIVITY_STOPPED -> {
                        val from = resumedAt.remove(pkg) ?: continue
                        totals[pkg] = (totals[pkg] ?: 0L) + (event.timeStamp - from)
                    }
                }
            }
            // Apps that are still open right now.
            for ((pkg, from) in resumedAt) {
                totals[pkg] = (totals[pkg] ?: 0L) + (now - from)
            }
        } catch (e: Exception) {
            // No usage permission: it cannot be measured, so it is not blocked.
            Log.w(TAG, "No se pudo consultar el uso de hoy", e)
            return emptyMap()
        }

        usageCache = totals
        usageCachedAt = nowElapsed
        usageCacheDay = day
        return totals
    }

    fun invalidateUsage() {
        usageCachedAt = 0L
    }

    /** Has [packageName] used up its time today? */
    fun isOverLimit(context: Context, packageName: String): Boolean {
        val limit = limitMinutes(context, packageName) ?: return false
        val used = usageToday(context)[packageName] ?: 0L
        return used >= limit * 60_000L
    }
}
