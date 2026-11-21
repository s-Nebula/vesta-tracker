package org.vestaopensource.tracker

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.SystemClock
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray
import java.net.IDN
import java.util.Locale

class AppBlockerService : AccessibilityService() {

    companion object {
        private const val TAG = "AppBlocker"
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val BLOCKED_APPS_KEY = "flutter.blocked_apps_json"
        private const val BLOCKED_DOMAINS_KEY = "flutter.blocked_domains_json"
        private const val ALLOWED_DOMAINS_KEY = "flutter.allowed_domains_json"
        private const val CHECKED_AT_KEY =
            "flutter.privacy_authorization_checked_at_ms"
        private const val AUTHORIZATION_LEASE_MS = 120_000L

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

        private fun isAuthorized(context: Context, purpose: String): Boolean {
            val prefs = context.getSharedPreferences(
                PREFS_NAME,
                Context.MODE_PRIVATE
            )

            val checkedAt = prefs.getLong(CHECKED_AT_KEY, 0L)
            val age = System.currentTimeMillis() - checkedAt

            if (
                checkedAt <= 0L ||
                age < 0L ||
                age > AUTHORIZATION_LEASE_MS
            ) {
                return false
            }

            return prefs.getBoolean(
                "flutter.privacy_${purpose}_enabled",
                false
            )
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

    override fun onServiceConnected() {
        super.onServiceConnected()
        loadRules()

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

        // Bloqueo de aplicaciones: requiere autorización vigente.
        if (
            event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            packageName in blockedApps &&
            isAuthorized(this, "app_filtering")
        ) {
            Log.i(TAG, "Aplicación bloqueada: $packageName")
            BlockAlertReporter.reportBlockedApp(this, packageName)
            returnToHome()
            return
        }

        // Bloqueo de dominios: requiere autorización vigente.
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

                // Última comprobación inmediatamente antes de bloquear.
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
