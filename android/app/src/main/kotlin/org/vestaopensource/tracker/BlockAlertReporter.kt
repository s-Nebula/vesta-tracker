package org.vestaopensource.tracker

import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.AuthResult
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.android.gms.tasks.Task
import java.security.MessageDigest
import java.util.Locale

object BlockAlertReporter {
    private const val TAG = "VestaBlockAlerts"
    private const val PREFS = "FlutterSharedPreferences"
    private const val CHILD_ID_KEY = "flutter.child_id"
    private const val CHECKED_AT_KEY =
        "flutter.privacy_authorization_checked_at_ms"
    private const val AUTHORIZATION_LEASE_MS = 120_000L

    private val lock = Any()

    @Volatile
    private var pendingAuth: Task<AuthResult>? = null

    private fun isAuthorized(context: Context, purpose: String): Boolean {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        val now = System.currentTimeMillis()
        val checkedAt = prefs.getLong(CHECKED_AT_KEY, 0L)
        val age = now - checkedAt

        if (checkedAt <= 0L || age < 0L || age > AUTHORIZATION_LEASE_MS) {
            return false
        }

        return prefs.getBoolean("flutter.privacy_alerts_enabled", false) &&
            prefs.getBoolean("flutter.privacy_${purpose}_enabled", false)
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
            title = "Aplicación bloqueada",
            subtitle = "Intentó abrir: $appLabel",
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
            title = "Acceso bloqueado",
            subtitle = "Intentó acceder a: $normalized",
            eventKey = "blocked_domain",
            extra = mapOf(
                "domain" to normalized,
                "source" to source
            )
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
        extra: Map<String, String>
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
                    context, childId, purpose, title, subtitle, eventKey, extra
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
                    context, childId, purpose, title, subtitle, eventKey, extra
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
        extra: Map<String, String>
    ) {
        // La autorización puede haber sido revocada mientras se autenticaba.
        if (!isAuthorized(context, purpose)) {
            Log.i(TAG, "Alerta descartada: autorización no vigente")
            return
        }

        val data = hashMapOf<String, Any>(
            "title" to title,
            "subtitle" to subtitle,
            "type" to "critical",
            "timestamp" to FieldValue.serverTimestamp(),
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
