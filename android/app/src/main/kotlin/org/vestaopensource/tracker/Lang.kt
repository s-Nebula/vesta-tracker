package org.vestaopensource.tracker

import java.util.Locale

/**
 * Language of native texts (notifications and alerts). Matches the Flutter
 * side: Spanish on Spanish phones, English otherwise.
 */
object Lang {
    val isSpanish: Boolean
        get() = Locale.getDefault().language == "es"

    fun t(es: String, en: String): String = if (isSpanish) es else en
}
