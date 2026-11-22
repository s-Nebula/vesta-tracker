package org.vestaopensource.tracker

import android.content.Context

/**
 * Validity of the privacy authorisation, shared with Flutter.
 *
 * Flutter stores the time of the last successful check with the server
 * (`privacy_authorization_checked_at_ms`) and the validity to apply
 * (`privacy_authorization_lease_ms`). An explicit server answer
 * (revocation, unlinking) sets `checked_at` to 0 and applies straight
 * away; a network drop, however, keeps the rules for the validity period
 * so protection cannot be turned off by cutting the Internet.
 */
object PrivacyLease {
    const val PREFS = "FlutterSharedPreferences"
    private const val CHECKED_AT_KEY = "flutter.privacy_authorization_checked_at_ms"
    private const val LEASE_KEY = "flutter.privacy_authorization_lease_ms"

    /** Value used if Flutter has not written the validity yet (older version). */
    private const val DEFAULT_LEASE_MS = 120_000L
    private const val MIN_LEASE_MS = 60_000L
    private const val MAX_LEASE_MS = 72L * 60 * 60 * 1000

    fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Is the last successful check still valid? */
    fun isFresh(context: Context): Boolean {
        val prefs = prefs(context)
        val checkedAt = prefs.getLong(CHECKED_AT_KEY, 0L)
        if (checkedAt <= 0L) return false

        val lease = prefs.getLong(LEASE_KEY, DEFAULT_LEASE_MS)
            .coerceIn(MIN_LEASE_MS, MAX_LEASE_MS)
        val age = System.currentTimeMillis() - checkedAt

        return age in 0..lease
    }

    /** Is this purpose (`app_filtering`, `alerts`, ...) authorised? */
    fun isAuthorized(context: Context, purpose: String): Boolean {
        return isFresh(context) &&
            prefs(context).getBoolean("flutter.privacy_${purpose}_enabled", false)
    }
}
