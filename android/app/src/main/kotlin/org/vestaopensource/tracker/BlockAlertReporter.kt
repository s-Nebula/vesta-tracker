package org.vestaopensource.tracker

import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.AuthResult
import com.google.firebase.Timestamp
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.android.gms.tasks.Task
import java.security.MessageDigest
import java.util.Locale

object BlockAlertReporter {
    private const val TAG = "VestaBlockAlerts"
    private const val PREFS = "FlutterSharedPreferences"
    private const val CHILD_ID_KEY = "flutter.child_id"

    private val lock = Any()

    @Volatile
    private var pendingAuth: Task<AuthResult>? = null

    private fun isAuthorized(context: Context, purpose: String): Boolean {
        return PrivacyLease.isAuthorized(context, "alerts") &&
            PrivacyLease.isAuthorized(context, purpose)
    }

    fun reportBlockedApp(context: Context, packageName: String) {
        val appContext = context.applicationContext

        if (!isAuthorized(appContext, "app_filtering")) return

        val appLabel = try {
            val info = appContext.packageManager.getApplicationInfo(packageName, 0)
            appContext.packageManager.getApplicationLabel(info).toString()
        } catch (_: PackageManager.NameNotFoundException) {
            packageName
        } catch (_: Exception) {
            packageName
        }

        report(
            appContext,
            purpose = "app_filtering",
            key = "app:$packageName",
            interval = 15_000L,
            title = Lang.t("Aplicación bloqueada", "App blocked"),
            subtitle = Lang.t("Intentó abrir: $appLabel", "Tried to open: $appLabel"),
            eventKey = "blocked_app",
            extra = mapOf("packageName" to packageName)
        )
    }

    fun reportBlockedDomain(context: Context, domain: String, source: String) {
        val normalized = domain.trim().lowercase(Locale.ROOT)
        if (normalized.isBlank()) return

        val appContext = context.applicationContext

        if (!isAuthorized(appContext, "domain_filtering")) return

        report(
            appContext,
            purpose = "domain_filtering",
            key = "domain:$normalized",
            interval = 30_000L,
            title = Lang.t("Acceso bloqueado", "Access blocked"),
            subtitle = Lang.t("Intentó acceder a: $normalized", "Tried to access: $normalized"),
            eventKey = "blocked_domain",
            extra = mapOf(
                "domain" to normalized,
                "source" to source
            )
        )
    }

    /**
     * Tampering notices: the minor turned off a protection
     * (accessibility, VPN). Deduplicated for 10 minutes.
     */
    fun reportTamper(
        context: Context,
        purpose: String,
        key: String,
        title: String,
        subtitle: String
    ) {
        val appContext = context.applicationContext
        if (!isAuthorized(appContext, purpose)) return

        report(
            appContext,
            purpose = purpose,
            key = "tamper:$key",
            interval = 10 * 60_000L,
            title = title,
            subtitle = subtitle,
            eventKey = key,
            extra = emptyMap()
        )
    }

    /** Once a day per app: "today's time is used up". */
    fun reportLimitReached(context: Context, packageName: String) {
        val appContext = context.applicationContext
        if (!isAuthorized(appContext, "app_filtering")) return

        val appLabel = try {
            val info = appContext.packageManager.getApplicationInfo(packageName, 0)
            appContext.packageManager.getApplicationLabel(info).toString()
        } catch (_: Exception) {
            packageName
        }
        val day = java.text.SimpleDateFormat("yyyy-MM-dd", Locale.ROOT)
            .format(java.util.Date())

        report(
            appContext,
            purpose = "app_filtering",
            key = "limit:$packageName:$day",
            interval = 24 * 60 * 60_000L,
            title = Lang.t("Tiempo diario agotado", "Daily time used up"),
            subtitle = Lang.t("Usó todo el tiempo de hoy en $appLabel", "Used all of today's time on $appLabel"),
            eventKey = "app_limit_reached",
            extra = mapOf("packageName" to packageName),
            type = "info"
        )
    }

    fun reportStudyModeBlock(context: Context, packageName: String) {
        val appContext = context.applicationContext
        if (!isAuthorized(appContext, "app_filtering")) return

        val appLabel = try {
            val info = appContext.packageManager.getApplicationInfo(packageName, 0)
            appContext.packageManager.getApplicationLabel(info).toString()
        } catch (_: Exception) {
            packageName
        }

        report(
            appContext,
            purpose = "app_filtering",
            key = "study:$packageName",
            // During study time repeated attempts are normal: one notice
            // per app every 30 minutes is enough.
            interval = 30 * 60_000L,
            title = Lang.t("Intento de uso en modo estudio", "Attempted use in study mode"),
            subtitle = Lang.t("Intentó abrir: $appLabel", "Tried to open: $appLabel"),
            eventKey = "study_mode_block",
            extra = mapOf("packageName" to packageName),
            type = "warning"
        )
    }

    private fun report(
        context: Context,
        purpose: String,
        key: String,
        interval: Long,
        title: String,
        subtitle: String,
        eventKey: String,
        extra: Map<String, String>,
        type: String = "critical"
    ) {
        if (!isAuthorized(context, purpose)) return

        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val childId = prefs.getString(CHILD_ID_KEY, null)

        if (childId.isNullOrBlank()) {
            Log.w(TAG, "No se registra la alerta: falta child_id")
            return
        }

        val digest = MessageDigest.getInstance("SHA-256")
            .digest(key.toByteArray())
            .joinToString("") { "%02x".format(it) }

        val dedupKey = "vesta_alert_$digest"
        val now = System.currentTimeMillis()

        synchronized(lock) {
            if (!isAuthorized(context, purpose)) return

            val previous = prefs.getLong(dedupKey, 0L)

            if (now - previous < interval) {
                Log.d(TAG, "Alerta duplicada omitida: $key")
                return
            }

            if (!prefs.edit().putLong(dedupKey, now).commit()) {
                Log.w(TAG, "No se pudo guardar el control de duplicados")
            }
        }

        try {
            if (!isAuthorized(context, purpose)) return

            if (FirebaseApp.getApps(context).isEmpty()) {
                FirebaseApp.initializeApp(context)
            }

            val auth = FirebaseAuth.getInstance()
            val currentUser = auth.currentUser

            if (currentUser != null) {
                writeAlert(
                    context, childId, purpose, title, subtitle, eventKey, extra, type
                )
                return
            }

            val task = synchronized(lock) {
                pendingAuth ?: auth.signInAnonymously().also {
                    pendingAuth = it
                }
            }

            task.addOnSuccessListener {
                synchronized(lock) {
                    if (pendingAuth === task) pendingAuth = null
                }

                writeAlert(
                    context, childId, purpose, title, subtitle, eventKey, extra, type
                )
            }.addOnFailureListener { error ->
                synchronized(lock) {
                    if (pendingAuth === task) pendingAuth = null
                }

                Log.e(TAG, "Falló la autenticación para registrar la alerta", error)
            }
        } catch (error: Exception) {
            Log.e(TAG, "No se pudo preparar el registro de la alerta", error)
        }
    }

    private fun writeAlert(
        context: Context,
        childId: String,
        purpose: String,
        title: String,
        subtitle: String,
        eventKey: String,
        extra: Map<String, String>,
        type: String
    ) {
        // The authorisation may have been revoked while authenticating.
        if (!isAuthorized(context, purpose)) {
            Log.i(TAG, "Alerta descartada: autorización no vigente")
            return
        }

        val data = hashMapOf<String, Any>(
            "title" to title,
            "subtitle" to subtitle,
            "type" to type,
            "timestamp" to FieldValue.serverTimestamp(),
            "occurredAt" to Timestamp.now(),
            "eventKey" to eventKey
        )

        extra.forEach { (key, value) -> data[key] = value }

        FirebaseFirestore.getInstance()
            .collection("children")
            .document(childId)
            .collection("alerts")
            .add(data)
            .addOnSuccessListener {
                Log.i(TAG, "Alerta registrada: $eventKey")
            }
            .addOnFailureListener { error ->
                Log.e(TAG, "Error guardando alerta: $eventKey", error)
            }
    }
}
