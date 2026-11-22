package org.vestaopensource.tracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.util.Log

class VpnBootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "VestaVpnBoot"
        private const val PREFS = "FlutterSharedPreferences"
    }

    private fun isAuthorized(context: Context): Boolean =
        PrivacyLease.isAuthorized(context, "domain_filtering")

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Intent.ACTION_BOOT_COMPLETED) return

        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val childId = prefs.getString("flutter.child_id", null)

        if (childId.isNullOrBlank()) {
            Log.i(TAG, "No hay dispositivo vinculado")
            return
        }

        if (!isAuthorized(context)) {
            Log.w(TAG, "Consentimiento DNS ausente o vencido; VPN no iniciada")
            return
        }

        if (VpnService.prepare(context) != null) {
            Log.w(TAG, "Falta autorización VPN; se requiere abrir la app")
            return
        }

        val serviceIntent = Intent(context, DnsVpnService::class.java).apply {
            action = DnsVpnService.ACTION_START
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        } catch (e: Exception) {
            Log.e(TAG, "No se pudo restaurar la VPN", e)
        }
    }
}
