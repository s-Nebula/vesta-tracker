package org.vestaopensource.tracker

import android.content.Intent
import android.content.ComponentName
import android.provider.Settings
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.VpnService
import android.os.Build
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import org.vestaopensource.tracker.update.UpdaterBridge

class MainActivity : FlutterActivity() {

    companion object {
        const val EXTRA_REQUEST_PACKAGE = "vesta_request_package"
        const val EXTRA_REQUEST_APP_NAME = "vesta_request_app_name"
        const val EXTRA_REQUEST_TYPE = "vesta_request_type"
    }

    /** Pending request opened from the block notification. */
    private var pendingRequest: Map<String, String>? = null

    private fun captureRequest(intent: Intent?) {
        val pkg = intent?.getStringExtra(EXTRA_REQUEST_PACKAGE) ?: return
        pendingRequest = mapOf(
            "packageName" to pkg,
            "appName" to (intent.getStringExtra(EXTRA_REQUEST_APP_NAME) ?: pkg),
            "type" to (intent.getStringExtra(EXTRA_REQUEST_TYPE) ?: "unlock_app")
        )
        intent.removeExtra(EXTRA_REQUEST_PACKAGE)
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        captureRequest(intent)
    }

    override fun onResume() {
        super.onResume()
        UpdaterBridge.onResume(this)
    }

    override fun onPause() {
        UpdaterBridge.onPause(this)
        super.onPause()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureRequest(intent)
    }

    private val CHANNEL = "com.vesta.blocker/apps"
    private val VPN_REQUEST_CODE = 7313
    private var pendingVpnResult: MethodChannel.Result? = null

    private fun isDomainFilteringAuthorized(): Boolean =
        PrivacyLease.isAuthorized(this, "domain_filtering")

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        UpdaterBridge.register(flutterEngine, this)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {
                "isAccessibilityServiceEnabled" -> {
                    try {
                        val enabledServices = Settings.Secure.getString(
                            contentResolver,
                            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
                        ).orEmpty()

                        val expected = ComponentName(
                            this,
                            AppBlockerService::class.java
                        )

                        val enabled = enabledServices
                            .split(':')
                            .mapNotNull { ComponentName.unflattenFromString(it) }
                            .any { it == expected }

                        result.success(enabled)
                    } catch (e: Exception) {
                        result.error(
                            "ACCESSIBILITY_CHECK_ERROR",
                            e.message,
                            null
                        )
                    }
                }
                "updateBlockedApps" -> {
                    val apps = call.argument<List<String>>("apps")
                    if (apps == null) {
                        result.error("INVALID_ARGUMENT", "Lista nula", null)
                    } else {
                        AppBlockerService.updateBlockedApps(this, apps)
                        result.success(true)
                    }
                }

                "startDnsVpn" -> {
                    if (!isDomainFilteringAuthorized()) {
                        result.error(
                            "PRIVACY_NOT_AUTHORIZED",
                            "El filtrado DNS no tiene autorización vigente.",
                            null
                        )
                        return@setMethodCallHandler
                    }

                    if (pendingVpnResult != null) {
                        result.error(
                            "VPN_REQUEST_PENDING",
                            "Ya existe una solicitud de permiso VPN.",
                            null
                        )
                        return@setMethodCallHandler
                    }

                    val permissionIntent = VpnService.prepare(this)

                    if (permissionIntent == null) {
                        startDnsVpnService()
                        result.success(true)
                    } else {
                        pendingVpnResult = result
                        try {
                            startActivityForResult(
                                permissionIntent,
                                VPN_REQUEST_CODE
                            )
                        } catch (e: Exception) {
                            pendingVpnResult = null
                            result.error(
                                "VPN_PERMISSION_ERROR",
                                e.message,
                                null
                            )
                        }
                    }
                }

                "consumePendingRequest" -> {
                    val request = pendingRequest
                    pendingRequest = null
                    result.success(request)
                }

                "stopDnsVpn" -> {
                    stopService(Intent(this, DnsVpnService::class.java))
                    result.success(true)
                }

                "getInstalledApps" -> {
                    try {
                        val intent = Intent(Intent.ACTION_MAIN).apply {
                            addCategory(Intent.CATEGORY_LAUNCHER)
                        }

                        val apps = packageManager.queryIntentActivities(intent, 0)
                            .mapNotNull { resolveInfo ->
                                val packageName =
                                    resolveInfo.activityInfo?.packageName
                                        ?: return@mapNotNull null

                                if (packageName == applicationContext.packageName) {
                                    return@mapNotNull null
                                }

                                val label =
                                    resolveInfo.loadLabel(packageManager).toString()
                                val drawable = resolveInfo.loadIcon(packageManager)

                                val bitmap = Bitmap.createBitmap(
                                    96,
                                    96,
                                    Bitmap.Config.ARGB_8888
                                )

                                val canvas = Canvas(bitmap)
                                drawable.setBounds(0, 0, 96, 96)
                                drawable.draw(canvas)

                                val output = ByteArrayOutputStream()
                                bitmap.compress(
                                    Bitmap.CompressFormat.PNG,
                                    85,
                                    output
                                )
                                bitmap.recycle()

                                mapOf(
                                    "packageName" to packageName,
                                    "name" to label,
                                    "iconBase64" to Base64.encodeToString(
                                        output.toByteArray(),
                                        Base64.NO_WRAP
                                    )
                                )
                            }
                            .distinctBy { it["packageName"] }
                            .sortedBy { it["name"]?.lowercase() }

                        result.success(apps)
                    } catch (e: Exception) {
                        result.error("APP_CATALOG_ERROR", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun startDnsVpnService() {
        val intent = Intent(this, DnsVpnService::class.java).apply {
            action = DnsVpnService.ACTION_START
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    @Deprecated("Deprecated in Android API; retained for VPN consent result")
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?
    ) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode != VPN_REQUEST_CODE) return

        val callback = pendingVpnResult
        pendingVpnResult = null

        if (resultCode == RESULT_OK) {
            if (!isDomainFilteringAuthorized()) {
                callback?.error(
                    "PRIVACY_NOT_AUTHORIZED",
                    "La autorización de filtrado DNS venció.",
                    null
                )
                return
            }

            try {
                startDnsVpnService()
                callback?.success(true)
            } catch (e: Exception) {
                callback?.error("VPN_START_ERROR", e.message, null)
            }
        } else {
            callback?.success(false)
        }
    }
}
