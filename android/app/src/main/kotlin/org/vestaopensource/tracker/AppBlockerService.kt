package org.vestaopensource.tracker

import android.accessibilityservice.AccessibilityService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import android.provider.Telephony
import android.telecom.TelecomManager
import android.view.inputmethod.InputMethodManager
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray
import org.json.JSONObject
import java.net.IDN
import java.util.Calendar
import java.util.Locale

class AppBlockerService : AccessibilityService() {

    companion object {
        private const val TAG = "AppBlocker"
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val BLOCKED_APPS_KEY = "flutter.blocked_apps_json"
        private const val BLOCKED_DOMAINS_KEY = "flutter.blocked_domains_json"
        private const val ALLOWED_DOMAINS_KEY = "flutter.allowed_domains_json"

        private const val STUDY_MODE_KEY = "flutter.study_mode_json"
        private const val VPN_HEAL_INTERVAL_MS = 60_000L

        /**
         * Packages never blocked in study mode: calls and emergencies,
         * system permissions and the Android interface itself.
         */
        private val ALWAYS_ALLOWED_IN_STUDY = setOf(
            "android",
            "com.android.systemui",
            "com.android.settings",
            "com.android.phone",
            "com.android.server.telecom",
            "com.android.emergency",
            "com.google.android.dialer",
            "com.google.android.apps.safetyhub",
            "com.android.permissioncontroller",
            "com.google.android.permissioncontroller",
            "com.android.packageinstaller",
            "com.google.android.packageinstaller",
            "com.android.vending",
            "com.google.android.inputmethod.latin",
            "com.samsung.android.honeyboard"
        )

        private const val BRAVE_PACKAGE = "com.brave.browser"
        private const val URL_BAR_ID = "com.brave.browser:id/url_bar"

        @Volatile
        private var blockedApps: Set<String> = emptySet()

        @Volatile
        private var blockedDomains: Set<String> = emptySet()

        @Volatile
        private var allowedDomains: Set<String> = emptySet()

        @Volatile
        private var lastBlockedHost = ""

        @Volatile
        private var lastBlockedAt = 0L

        private fun isAuthorized(context: Context, purpose: String): Boolean =
            PrivacyLease.isAuthorized(context, purpose)

        private class StudySchedule(
            val days: Set<Int>,
            val start: Int,
            val end: Int
        ) {
            /** Same logic as StudySchedule in Dart (study_mode_state.dart). */
            fun isActive(isoDay: Int, minutes: Int): Boolean {
                if (end > start) {
                    return isoDay in days && minutes >= start && minutes < end
                }
                val yesterday = if (isoDay == 1) 7 else isoDay - 1
                return (isoDay in days && minutes >= start) ||
                    (yesterday in days && minutes < end)
            }
        }

        private class StudyMode(
            val manualActive: Boolean,
            val endsAtMs: Long,
            val allowedApps: Set<String>,
            val schedules: List<StudySchedule>
        ) {
            fun isActive(nowMs: Long): Boolean {
                if (manualActive && (endsAtMs <= 0L || nowMs < endsAtMs)) {
                    return true
                }
                if (schedules.isEmpty()) return false

                val calendar = Calendar.getInstance().apply { timeInMillis = nowMs }
                val dow = calendar.get(Calendar.DAY_OF_WEEK)
                val isoDay = if (dow == Calendar.SUNDAY) 7 else dow - 1
                val minutes = calendar.get(Calendar.HOUR_OF_DAY) * 60 +
                    calendar.get(Calendar.MINUTE)

                return schedules.any { it.isActive(isoDay, minutes) }
            }
        }

        private fun parseTime(value: String): Int? {
            val match = Regex("^([01]\\d|2[0-3]):([0-5]\\d)$").find(value) ?: return null
            return match.groupValues[1].toInt() * 60 + match.groupValues[2].toInt()
        }

        private fun parseStudyMode(json: String?): StudyMode? {
            if (json.isNullOrBlank()) return null

            return try {
                val data = JSONObject(json)
                val allowed = data.optJSONArray("allowedApps") ?: JSONArray()
                val rawSchedules = data.optJSONArray("schedules") ?: JSONArray()

                val schedules = (0 until rawSchedules.length()).mapNotNull { index ->
                    val item = rawSchedules.optJSONObject(index) ?: return@mapNotNull null
                    val start = parseTime(item.optString("start")) ?: return@mapNotNull null
                    val end = parseTime(item.optString("end")) ?: return@mapNotNull null
                    if (start == end) return@mapNotNull null
                    val rawDays = item.optJSONArray("days") ?: return@mapNotNull null
                    val days = (0 until rawDays.length())
                        .map { rawDays.optInt(it, 0) }
                        .filter { it in 1..7 }
                        .toSet()
                    if (days.isEmpty()) null else StudySchedule(days, start, end)
                }

                StudyMode(
                    manualActive = data.optBoolean("active", false),
                    endsAtMs = data.optLong("endsAtMs", 0L),
                    allowedApps = (0 until allowed.length())
                        .mapNotNull { allowed.optString(it).takeIf(String::isNotBlank) }
                        .toSet(),
                    schedules = schedules
                )
            } catch (e: Exception) {
                Log.e(TAG, "Configuración de modo estudio no válida", e)
                null
            }
        }

        fun updateBlockedApps(context: Context, apps: List<String>) {
            val normalized = if (isAuthorized(context, "app_filtering")) {
                apps.map { it.trim() }
                    .filter { it.isNotEmpty() }
                    .toSet()
            } else {
                emptySet()
            }

            blockedApps = normalized

            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(
                    BLOCKED_APPS_KEY,
                    JSONArray(normalized.toList()).toString()
                )
                .apply()
        }

        private fun readJsonSet(context: Context, key: String): Set<String> {
            val json = context.getSharedPreferences(
                PREFS_NAME,
                Context.MODE_PRIVATE
            ).getString(key, "[]") ?: "[]"

            return try {
                val array = JSONArray(json)
                (0 until array.length())
                    .mapNotNull {
                        array.optString(it).takeIf(String::isNotBlank)
                    }
                    .toSet()
            } catch (e: Exception) {
                Log.e(TAG, "Error leyendo reglas: $key", e)
                emptySet()
            }
        }

        private fun normalizeDomain(value: String): String? {
            var candidate = value.trim().lowercase(Locale.ROOT)
            if (candidate.isEmpty()) return null

            candidate = candidate.removePrefix("*.")
                .removePrefix(".")

            val parsed = Uri.parse(
                if (candidate.contains("://")) {
                    candidate
                } else {
                    "https://$candidate"
                }
            )

            val host = parsed.host
                ?.trimEnd('.')
                ?.lowercase(Locale.ROOT)
                ?: return null

            return try {
                IDN.toASCII(host).lowercase(Locale.ROOT)
            } catch (_: IllegalArgumentException) {
                null
            }
        }

        private fun hostMatchesRule(host: String, rule: String): Boolean {
            return host == rule || host.endsWith(".$rule")
        }
    }

    private var studyModeJson: String? = null
    private var studyMode: StudyMode? = null
    private var essentialPackages: Set<String> = emptySet()
    private var essentialRefreshedAt = 0L
    private val launchableCache = HashMap<String, Boolean>()
    private var lastVpnHealAt = 0L
    private var currentForeground: String? = null
    private val periodicHandler = android.os.Handler(android.os.Looper.getMainLooper())

    /**
     * Checks the foreground app every 30 s: the daily limit or study mode
     * can start while the app is already open, without any window-change
     * event arriving.
     */
    private val periodicCheck = object : Runnable {
        override fun run() {
            try {
                loadRules()
                currentForeground?.let { enforceAppPolicy(it, periodic = true) }
            } catch (e: Exception) {
                Log.w(TAG, "Error en la comprobación periódica", e)
            }
            periodicHandler.postDelayed(this, 30_000L)
        }
    }

    /**
     * Applies, in order, the rules for [packageName]. Returns true if it was
     * blocked. A temporary permission approved by the guardian takes priority.
     */
    private fun enforceAppPolicy(packageName: String, periodic: Boolean = false): Boolean {
        if (!isAuthorized(this, "app_filtering")) return false
        if (packageName == applicationContext.packageName) return false
        if (AppTimePolicy.isTemporarilyAllowed(this, packageName)) return false

        val reason = when {
            packageName in blockedApps -> BlockNotifier.Reason.BLOCKED
            shouldBlockForStudyMode(packageName) -> BlockNotifier.Reason.STUDY
            AppTimePolicy.isOverLimit(this, packageName) -> BlockNotifier.Reason.LIMIT
            else -> return false
        }

        Log.i(TAG, "Bloqueo ($reason${if (periodic) ", periódico" else ""}): $packageName")
        when (reason) {
            BlockNotifier.Reason.BLOCKED -> BlockAlertReporter.reportBlockedApp(this, packageName)
            BlockNotifier.Reason.STUDY -> BlockAlertReporter.reportStudyModeBlock(this, packageName)
            BlockNotifier.Reason.LIMIT -> BlockAlertReporter.reportLimitReached(this, packageName)
        }
        BlockNotifier.show(this, packageName, reason)
        currentForeground = null
        returnToHome()
        return true
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        loadRules()
        refreshEssentialPackages()
        periodicHandler.removeCallbacks(periodicCheck)
        periodicHandler.postDelayed(periodicCheck, 30_000L)

        Log.i(
            TAG,
            "Servicio activo. Aplicaciones: ${blockedApps.size}, " +
                "dominios: ${blockedDomains.size}"
        )
    }

    private fun loadRules() {
        blockedApps = if (isAuthorized(this, "app_filtering")) {
            readJsonSet(this, BLOCKED_APPS_KEY)
        } else {
            emptySet()
        }

        val json = if (isAuthorized(this, "app_filtering")) {
            getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .getString(STUDY_MODE_KEY, null)
        } else {
            null
        }

        if (json != studyModeJson) {
            studyModeJson = json
            studyMode = parseStudyMode(json)
        }

        if (isAuthorized(this, "domain_filtering")) {
            blockedDomains = readJsonSet(this, BLOCKED_DOMAINS_KEY)
                .mapNotNull(::normalizeDomain)
                .toSet()

            allowedDomains = readJsonSet(this, ALLOWED_DOMAINS_KEY)
                .mapNotNull(::normalizeDomain)
                .toSet()
        } else {
            blockedDomains = emptySet()
            allowedDomains = emptySet()
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return

        loadRules()

        val packageName = event.packageName?.toString() ?: return

        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            currentForeground = packageName
            if (enforceAppPolicy(packageName)) return
        }

        healDnsVpnIfNeeded()

        // Domain blocking: requires a valid authorisation.
        if (
            packageName != BRAVE_PACKAGE ||
            blockedDomains.isEmpty() ||
            !isAuthorized(this, "domain_filtering")
        ) {
            return
        }

        if (
            event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            event.eventType != AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED &&
            event.eventType != AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED
        ) {
            return
        }

        val root = rootInActiveWindow ?: return

        try {
            val urlNode = findUrlBar(root) ?: return

            try {
                if (urlNode.isFocused) return

                val rawUrl = urlNode.text?.toString()
                    ?.takeIf { it.isNotBlank() }
                    ?: urlNode.contentDescription?.toString()
                        ?.takeIf { it.isNotBlank() }
                    ?: return

                val host = normalizeDomain(rawUrl) ?: return

                val blockedSpecificity = blockedDomains
                    .filter { rule -> hostMatchesRule(host, rule) }
                    .maxOfOrNull { it.length } ?: -1

                val allowedSpecificity = allowedDomains
                    .filter { rule -> hostMatchesRule(host, rule) }
                    .maxOfOrNull { it.length } ?: -1

                if (blockedSpecificity < 0) return
                if (allowedSpecificity >= blockedSpecificity) return

                // Last check right before blocking.
                if (!isAuthorized(this, "domain_filtering")) return

                val now = SystemClock.elapsedRealtime()

                if (host == lastBlockedHost && now - lastBlockedAt < 5000L) {
                    return
                }

                lastBlockedHost = host
                lastBlockedAt = now

                Log.i(TAG, "Navegación bloqueada por regla de dominio: $host")

                BlockAlertReporter.reportBlockedDomain(
                    this,
                    host,
                    "accessibility"
                )

                returnToHome()
            } finally {
                urlNode.recycle()
            }
        } finally {
            root.recycle()
        }
    }

    private fun findUrlBar(
        node: AccessibilityNodeInfo,
        depth: Int = 0
    ): AccessibilityNodeInfo? {
        if (depth > 15) return null

        if (node.viewIdResourceName == URL_BAR_ID) {
            return AccessibilityNodeInfo.obtain(node)
        }

        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue

            val result = try {
                findUrlBar(child, depth + 1)
            } finally {
                child.recycle()
            }

            if (result != null) return result
        }

        return null
    }

    private fun shouldBlockForStudyMode(packageName: String): Boolean {
        val mode = studyMode ?: return false
        if (!isAuthorized(this, "app_filtering")) return false
        if (!mode.isActive(System.currentTimeMillis())) return false
        if (packageName in mode.allowedApps) return false

        val now = SystemClock.elapsedRealtime()
        if (now - essentialRefreshedAt > 10 * 60_000L) refreshEssentialPackages()
        if (packageName in essentialPackages) return false

        // Only apps the user can open from the launcher are blocked;
        // system components without an icon are never touched.
        return launchableCache.getOrPut(packageName) {
            packageManager.getLaunchIntentForPackage(packageName) != null
        }
    }

    private fun refreshEssentialPackages() {
        val packages = HashSet(ALWAYS_ALLOWED_IN_STUDY)
        packages.add(applicationContext.packageName)

        try {
            val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
            packageManager.queryIntentActivities(home, 0)
                .mapNotNull { it.activityInfo?.packageName }
                .forEach(packages::add)
        } catch (e: Exception) {
            Log.w(TAG, "No se pudo resolver el lanzador", e)
        }

        try {
            val telecom = getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
            telecom?.defaultDialerPackage?.let(packages::add)
        } catch (e: Exception) {
            Log.w(TAG, "No se pudo resolver el marcador", e)
        }

        try {
            Telephony.Sms.getDefaultSmsPackage(this)?.let(packages::add)
        } catch (e: Exception) {
            Log.w(TAG, "No se pudo resolver la app de SMS", e)
        }

        try {
            val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
            imm?.enabledInputMethodList?.forEach { packages.add(it.packageName) }
            Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
                ?.let(ComponentName::unflattenFromString)
                ?.packageName
                ?.let(packages::add)
        } catch (e: Exception) {
            Log.w(TAG, "No se pudieron resolver los teclados", e)
        }

        essentialPackages = packages
        essentialRefreshedAt = SystemClock.elapsedRealtime()
        launchableCache.clear()
    }

    /**
     * If the web filter is authorised but the VPN is not running (for
     * example after a reboot without opening the app), it is started again. Only
     * possible if the user already granted the VPN permission before.
     */
    private fun healDnsVpnIfNeeded() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastVpnHealAt < VPN_HEAL_INTERVAL_MS) return
        lastVpnHealAt = now

        if (DnsVpnService.isActive) return
        if (!isAuthorized(this, "domain_filtering")) return

        try {
            if (VpnService.prepare(this) != null) return

            val intent = Intent(this, DnsVpnService::class.java).apply {
                action = DnsVpnService.ACTION_START
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }

            Log.i(TAG, "Protección DNS restaurada automáticamente")
        } catch (e: Exception) {
            Log.w(TAG, "No se pudo restaurar la protección DNS", e)
        }
    }

    override fun onDestroy() {
        periodicHandler.removeCallbacks(periodicCheck)
        super.onDestroy()
    }

    override fun onUnbind(intent: Intent?): Boolean {
        // Android unbinds the service when it is turned off in Settings >
        // Accessibility. It is the most common way to bypass blocking.
        BlockAlertReporter.reportTamper(
            this,
            purpose = "app_filtering",
            key = "accessibility_disabled",
            title = Lang.t("Bloqueo de apps desactivado", "App blocking turned off"),
            subtitle = Lang.t("Se desactivó el servicio de accesibilidad de Vesta en el dispositivo.", "Vesta's accessibility service was turned off on the device.")
        )
        return super.onUnbind(intent)
    }

    private fun returnToHome() {
        val homeIntent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_HOME)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }

        startActivity(homeIntent)
    }

    override fun onInterrupt() {
        Log.w(TAG, "Servicio interrumpido")
    }
}
