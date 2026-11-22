package org.vestaopensource.tracker

import java.io.ByteArrayOutputStream
import java.util.Locale

/**
 * DNS utilities for web protection:
 *
 * * **Forced SafeSearch**: A queries for Google, YouTube, Bing and
 *   DuckDuckGo are answered with the IPs of their "safe" services
 *   (forcesafesearch.google.com, restrict.youtube.com, strict.bing.com,
 *   safe.duckduckgo.com). It is the same mechanism schools and family
 *   routers use and it needs no browser changes.
 * * **Encrypted DNS (DoH) blocking**: if the minor sets "secure DNS" in the
 *   browser, queries stop going through the filter. Resolution of the known
 *   DoH providers is blocked so that option does not work, and NXDOMAIN is
 *   returned for Firefox's canary domain (use-application-dns.net), which
 *   tells it to turn DoH off.
 */
object DnsTools {
    const val TYPE_A = 1
    const val TYPE_AAAA = 28
    const val TYPE_HTTPS = 65

    private val GOOGLE = Regex("^(www\\.)?google\\.(com|[a-z]{2}|com?\\.[a-z]{2})$")

    private val YOUTUBE = setOf(
        "youtube.com",
        "www.youtube.com",
        "m.youtube.com",
        "youtubei.googleapis.com",
        "youtube.googleapis.com",
        "www.youtube-nocookie.com",
    )

    private val BING = setOf("bing.com", "www.bing.com")
    private val DUCKDUCKGO = setOf("duckduckgo.com", "www.duckduckgo.com")

    private const val DOH_CANARY = "use-application-dns.net"

    private val DOH_HOSTS = setOf(
        "dns.google", "dns.google.com", "dns64.dns.google", "8888.google",
        "cloudflare-dns.com", "mozilla.cloudflare-dns.com",
        "chrome.cloudflare-dns.com", "1dot1dot1dot1.cloudflare-dns.com",
        "security.cloudflare-dns.com", "family.cloudflare-dns.com",
        "one.one.one.one", "dns.quad9.net", "dns9.quad9.net",
        "dns10.quad9.net", "dns11.quad9.net", "doh.opendns.com",
        "doh.familyshield.opendns.com", "dns.adguard.com",
        "dns.adguard-dns.com", "dns-family.adguard.com",
        "unfiltered.adguard-dns.com", "dns.nextdns.io",
        "doh.cleanbrowsing.org", "doh.mullvad.net", "dns.mullvad.net",
        "doh.dns.sb", "dns.controld.com", "freedns.controld.com",
        "doh.libredns.gr", "dns.alidns.com", "doh.pub", "dns.twnic.tw",
    )

    fun isDohCanary(domain: String) = domain == DOH_CANARY

    fun isDohHost(domain: String): Boolean =
        DOH_HOSTS.any { domain == it || domain.endsWith(".$it") }

    /** "Safe" name [domain] is redirected to, or null if it does not apply. */
    fun safeSearchTarget(domain: String): String? {
        val d = domain.lowercase(Locale.ROOT)
        return when {
            GOOGLE.matches(d) -> "forcesafesearch.google.com"
            d in YOUTUBE -> "restrict.youtube.com"
            d in BING -> "strict.bing.com"
            d in DUCKDUCKGO -> "safe.duckduckgo.com"
            else -> null
        }
    }

    /** Offset right after the name that starts at [start]. */
    private fun skipName(data: ByteArray, start: Int): Int {
        var position = start
        while (position < data.size) {
            val length = data[position].toInt() and 0xFF
            if (length == 0) return position + 1
            if ((length and 0xC0) == 0xC0) return position + 2
            position += length + 1
        }
        return -1
    }

    private fun u16(data: ByteArray, offset: Int): Int =
        ((data[offset].toInt() and 0xFF) shl 8) or (data[offset + 1].toInt() and 0xFF)

    /** Type (A, AAAA...) of the first question, or -1. */
    fun queryType(query: ByteArray): Int {
        if (query.size < 17) return -1
        val end = skipName(query, 12)
        if (end < 0 || end + 4 > query.size) return -1
        return u16(query, end)
    }

    /** Recursive A/AAAA query for [name]. */
    fun buildQuery(id: Int, name: String, type: Int): ByteArray {
        val out = ByteArrayOutputStream()
        out.write((id shr 8) and 0xFF); out.write(id and 0xFF)
        out.write(0x01); out.write(0x00) // RD
        out.write(0); out.write(1) // QDCOUNT
        repeat(6) { out.write(0) }
        for (label in name.trimEnd('.').split('.')) {
            val bytes = label.toByteArray(Charsets.US_ASCII)
            out.write(bytes.size)
            out.write(bytes)
        }
        out.write(0)
        out.write((type shr 8) and 0xFF); out.write(type and 0xFF)
        out.write(0); out.write(1) // IN
        return out.toByteArray()
    }

    /** IPv4 addresses in the answer section (follows CNAME implicitly). */
    fun parseARecords(response: ByteArray): List<ByteArray> {
        if (response.size < 12) return emptyList()
        val questions = u16(response, 4)
        val answers = u16(response, 6)
        var position = 12

        repeat(questions) {
            position = skipName(response, position)
            if (position < 0) return emptyList()
            position += 4
        }

        val result = mutableListOf<ByteArray>()
        repeat(answers) {
            position = skipName(response, position)
            if (position < 0 || position + 10 > response.size) return result
            val type = u16(response, position)
            val length = u16(response, position + 8)
            position += 10
            if (position + length > response.size) return result
            if (type == TYPE_A && length == 4) {
                result.add(response.copyOfRange(position, position + 4))
            }
            position += length
        }
        return result
    }

    /**
     * Answer to [query] with the given A records (empty list =
     * NOERROR with no data, useful so AAAA/HTTPS don't skip the redirect).
     */
    fun buildAnswer(query: ByteArray, ips: List<ByteArray>, ttl: Int = 300): ByteArray? {
        val questionEnd = skipName(query, 12)
        if (questionEnd < 0 || questionEnd + 4 > query.size) return null

        val out = ByteArrayOutputStream()
        out.write(query[0].toInt()); out.write(query[1].toInt())
        val rd = query[2].toInt() and 0x01
        out.write(0x80 or rd) // QR + RD
        out.write(0x80) // RA, RCODE 0
        out.write(0); out.write(1)
        out.write((ips.size shr 8) and 0xFF); out.write(ips.size and 0xFF)
        repeat(4) { out.write(0) }
        out.write(query, 12, questionEnd + 4 - 12)

        for (ip in ips) {
            out.write(0xC0); out.write(0x0C) // pointer to the question name
            out.write(0); out.write(TYPE_A)
            out.write(0); out.write(1)
            out.write((ttl shr 24) and 0xFF); out.write((ttl shr 16) and 0xFF)
            out.write((ttl shr 8) and 0xFF); out.write(ttl and 0xFF)
            out.write(0); out.write(4)
            out.write(ip)
        }
        return out.toByteArray()
    }
}
