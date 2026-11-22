package org.vestaopensource.tracker

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.IDN
import java.net.Inet4Address
import java.net.InetAddress
import java.net.URI
import java.nio.ByteBuffer
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

class DnsVpnService : VpnService() {

    companion object {
        const val ACTION_START = "org.vestaopensource.tracker.VPN_START"
        const val ACTION_STOP = "org.vestaopensource.tracker.VPN_STOP"
        private const val TAG = "VestaDnsVPN"
        private const val CHANNEL_ID = "vesta_dns_vpn"
        private const val NOTIFICATION_ID = 7312
        private const val PREFS = "FlutterSharedPreferences"
        private const val DOMAINS_KEY = "flutter.blocked_domains_json"
        private const val WEB_PROTECTION_KEY = "flutter.web_protection_json"
        private const val WATCHDOG_INTERVAL_MS = 5_000L

        /** Tunnel state visible to AppBlockerService (self-repair). */
        @Volatile
        var isActive: Boolean = false
            private set

        private const val VPN_ADDRESS = "10.111.222.1"
        private const val DNS_ADDRESS = "10.111.222.2"
    }

    private var tunnel: ParcelFileDescriptor? = null
    private var worker: Thread? = null
    private val running = AtomicBoolean(false)
    private val watchdogHandler = Handler(Looper.getMainLooper())

    private fun isAuthorized(): Boolean =
        PrivacyLease.isAuthorized(this, "domain_filtering")

    private val authorizationWatchdog = object : Runnable {
        override fun run() {
            if (!running.get()) return

            if (!isAuthorized()) {
                Log.w(TAG, "Autorización DNS revocada o vencida; deteniendo VPN")
                stopVpn()
                stopSelf()
                return
            }

            watchdogHandler.postDelayed(this, WATCHDOG_INTERVAL_MS)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopVpn()
            stopSelf()
            return START_NOT_STICKY
        }

        if (!isAuthorized()) {
            Log.w(TAG, "Inicio VPN rechazado: no hay autorización vigente")
            stopVpn()
            stopSelf()
            return START_NOT_STICKY
        }

        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())

        if (!running.get()) {
            startVpn()
        }

        return START_NOT_STICKY
    }

    private fun startVpn() {
        if (!isAuthorized()) {
            Log.w(TAG, "No se establece VPN sin autorización vigente")
            stopSelf()
            return
        }

        try {
            val descriptor = Builder()
                .setSession(Lang.t("Vesta Tracker - Protección DNS", "Vesta Tracker - DNS protection"))
                .setMtu(1500)
                .addAddress(VPN_ADDRESS, 32)
                .addDnsServer(DNS_ADDRESS)
                .addRoute(DNS_ADDRESS, 32)
                .establish()

            if (descriptor == null) {
                Log.e(TAG, "Android no permitió establecer la interfaz VPN")
                stopSelf()
                return
            }

            tunnel = descriptor
            running.set(true)
            isActive = true
            watchdogHandler.removeCallbacks(authorizationWatchdog)
            watchdogHandler.postDelayed(authorizationWatchdog, WATCHDOG_INTERVAL_MS)

            worker = Thread {
                processPackets(descriptor)
            }.apply {
                name = "VestaDnsWorker"
                isDaemon = true
                start()
            }

            Log.i(TAG, "VPN DNS iniciado")
        } catch (e: Exception) {
            Log.e(TAG, "No se pudo iniciar la VPN", e)
            stopVpn()
            stopSelf()
        }
    }

    private fun processPackets(descriptor: ParcelFileDescriptor) {
        val input = FileInputStream(descriptor.fileDescriptor)
        val output = FileOutputStream(descriptor.fileDescriptor)
        val buffer = ByteArray(32767)

        try {
            while (running.get()) {
                val length = input.read(buffer)
                if (length <= 0) continue

                if (!isAuthorized()) {
                    Log.w(TAG, "Autorización DNS vencida durante el procesamiento")
                    break
                }

                val packet = buffer.copyOf(length)
                val dnsQuery = extractDnsQuery(packet) ?: continue

                val response = try {
                    val domain = readQueryDomain(dnsQuery)
                    val web = webProtection()
                    val safeTarget = if (domain != null && web.safeSearch) {
                        DnsTools.safeSearchTarget(domain)
                    } else {
                        null
                    }

                    when {
                        domain != null && isBlocked(domain) -> {
                            Log.i(TAG, "Dominio bloqueado: $domain")
                            BlockAlertReporter.reportBlockedDomain(this, domain, "vpn")
                            makeDnsError(dnsQuery, 3)
                        }
                        // Firefox turns its DoH off if this domain does not exist.
                        domain != null && DnsTools.isDohCanary(domain) ->
                            makeDnsError(dnsQuery, 3)
                        domain != null && web.blockDoh && DnsTools.isDohHost(domain) -> {
                            Log.i(TAG, "Proveedor de DNS cifrado bloqueado: $domain")
                            makeDnsError(dnsQuery, 3)
                        }
                        safeTarget != null ->
                            safeSearchResponse(dnsQuery, safeTarget)
                                ?: makeDnsError(dnsQuery, 2)
                        else -> forwardDns(dnsQuery) ?: makeDnsError(dnsQuery, 2)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error procesando consulta DNS", e)
                    makeDnsError(dnsQuery, 2)
                }

                val reply = buildIpv4UdpReply(packet, response)
                if (reply != null && running.get()) {
                    output.write(reply)
                }
            }
        } catch (e: Exception) {
            if (running.get()) {
                Log.e(TAG, "Error leyendo la interfaz VPN", e)
            }
        } finally {
            running.set(false)
        }
    }

    private data class UdpQuery(
        val dns: ByteArray,
        val sourceAddress: ByteArray,
        val sourcePort: Int
    )

    private fun extractDnsQuery(packet: ByteArray): ByteArray? {
        if (packet.size < 28) return null
        if ((packet[0].toInt() ushr 4) != 4) return null

        val headerLength = (packet[0].toInt() and 0x0F) * 4
        if (headerLength < 20 || packet.size < headerLength + 8) return null
        if (packet[9].toInt() and 0xFF != 17) return null

        val fragment = ((packet[6].toInt() and 0xFF) shl 8) or
            (packet[7].toInt() and 0xFF)
        if ((fragment and 0x1FFF) != 0) return null

        val destination = InetAddress.getByAddress(
            packet.copyOfRange(16, 20)
        ).hostAddress

        if (destination != DNS_ADDRESS) return null

        val udpOffset = headerLength
        val destinationPort =
            ((packet[udpOffset + 2].toInt() and 0xFF) shl 8) or
                (packet[udpOffset + 3].toInt() and 0xFF)

        if (destinationPort != 53) return null

        val udpLength =
            ((packet[udpOffset + 4].toInt() and 0xFF) shl 8) or
                (packet[udpOffset + 5].toInt() and 0xFF)

        if (udpLength < 8 || packet.size < udpOffset + udpLength) return null

        return packet.copyOfRange(udpOffset + 8, udpOffset + udpLength)
    }

    private fun readQueryDomain(dns: ByteArray): String? {
        if (dns.size < 17) return null

        var position = 12
        val labels = mutableListOf<String>()

        while (position < dns.size) {
            val size = dns[position].toInt() and 0xFF
            position++

            if (size == 0) break
            if ((size and 0xC0) != 0 || size > 63) return null
            if (position + size > dns.size) return null

            labels.add(
                String(dns, position, size, Charsets.US_ASCII)
            )
            position += size
        }

        if (labels.isEmpty()) return null

        return try {
            IDN.toASCII(labels.joinToString("."))
                .trimEnd('.')
                .lowercase(Locale.ROOT)
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    private fun isBlocked(domain: String): Boolean {
        if (!isAuthorized()) return false

        val json = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(DOMAINS_KEY, "[]") ?: "[]"

        val rules = try {
            val array = JSONArray(json)
            (0 until array.length()).mapNotNull {
                normalizeDomain(array.optString(it))
            }
        } catch (e: Exception) {
            Log.e(TAG, "No se pudieron leer las reglas DNS", e)
            emptyList()
        }

        return rules.any { rule ->
            domain == rule || domain.endsWith(".$rule")
        }
    }

    private fun normalizeDomain(value: String): String? {
        var candidate = value.trim().lowercase(Locale.ROOT)
        if (candidate.isEmpty()) return null

        candidate = candidate.removePrefix("*.")
            .removePrefix(".")

        val host = try {
            if (candidate.contains("://")) {
                URI(candidate).host
            } else {
                URI("https://$candidate").host
            }
        } catch (_: Exception) {
            null
        } ?: return null

        return try {
            IDN.toASCII(host.trimEnd('.')).lowercase(Locale.ROOT)
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    private data class WebProtection(val safeSearch: Boolean, val blockDoh: Boolean)

    @Volatile private var webJson: String? = null
    @Volatile private var webCache = WebProtection(safeSearch = false, blockDoh = true)

    /** Guardian settings (controls/web_protection), copied by Flutter. */
    private fun webProtection(): WebProtection {
        val json = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(WEB_PROTECTION_KEY, null)
        if (json != webJson) {
            webJson = json
            webCache = try {
                val data = if (json.isNullOrBlank()) null else JSONObject(json)
                WebProtection(
                    safeSearch = data?.optBoolean("safeSearch", false) ?: false,
                    // Encrypted DNS is blocked by default: without this the filter
                    // is turned off with a browser option.
                    blockDoh = data?.optBoolean("blockDoh", true) ?: true,
                )
            } catch (e: Exception) {
                Log.e(TAG, "Ajustes de protección web no válidos", e)
                WebProtection(safeSearch = false, blockDoh = true)
            }
        }
        return webCache
    }

    /**
     * Answers a search engine query with the IPs of its safe version.
     * Returns null if it could not be resolved (SERVFAIL is returned: better
     * than letting the search through unfiltered).
     */
    private fun safeSearchResponse(query: ByteArray, target: String): ByteArray? {
        return when (DnsTools.queryType(query)) {
            DnsTools.TYPE_A -> {
                val id = (System.nanoTime() and 0xFFFF).toInt()
                val upstream = forwardDns(DnsTools.buildQuery(id, target, DnsTools.TYPE_A))
                    ?: return null
                val ips = DnsTools.parseARecords(upstream)
                if (ips.isEmpty()) null else DnsTools.buildAnswer(query, ips)
            }
            // No IPv6 or HTTPS records: forces the client to use the redirected
            // IPv4 instead of connecting to the unfiltered version.
            DnsTools.TYPE_AAAA, DnsTools.TYPE_HTTPS -> DnsTools.buildAnswer(query, emptyList())
            else -> forwardDns(query)
        }
    }

    private fun forwardDns(query: ByteArray): ByteArray? {
        if (!isAuthorized()) return null

        val connectivity =
            getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        val upstream = connectivity.allNetworks
            .asSequence()
            .filter { network ->
                val capabilities = connectivity.getNetworkCapabilities(network)
                capabilities != null &&
                    capabilities.hasCapability(
                        NetworkCapabilities.NET_CAPABILITY_INTERNET
                    ) &&
                    !capabilities.hasTransport(
                        NetworkCapabilities.TRANSPORT_VPN
                    )
            }
            .flatMap { network ->
                connectivity.getLinkProperties(network)
                    ?.dnsServers
                    ?.asSequence() ?: emptySequence()
            }
            .firstOrNull {
                it is Inet4Address && it.hostAddress != DNS_ADDRESS
            } ?: return null

        val socket = DatagramSocket()
        try {
            if (!protect(socket)) {
                Log.e(TAG, "No se pudo excluir el socket de la VPN")
                return null
            }

            socket.soTimeout = 4000

            if (!isAuthorized()) return null

            val destination = InetAddress.getByAddress(upstream.address)
            socket.send(
                DatagramPacket(query, query.size, destination, 53)
            )

            val buffer = ByteArray(4096)
            val response = DatagramPacket(buffer, buffer.size)
            socket.receive(response)

            return response.data.copyOf(response.length)
        } finally {
            socket.close()
        }
    }

    private fun makeDnsError(query: ByteArray, rcode: Int): ByteArray {
        val response = query.copyOf()
        if (response.size < 12) return response

        val flags = ((response[2].toInt() and 0xFF) shl 8) or
            (response[3].toInt() and 0xFF)

        val newFlags = (flags and 0x7900) or 0x8080 or rcode
        response[2] = (newFlags ushr 8).toByte()
        response[3] = newFlags.toByte()

        // No answers, authority or additional records.
        response[6] = 0
        response[7] = 0
        response[8] = 0
        response[9] = 0
        response[10] = 0
        response[11] = 0

        return response
    }

    private fun buildIpv4UdpReply(
        original: ByteArray,
        dnsResponse: ByteArray
    ): ByteArray? {
        if (original.size < 28 || dnsResponse.size > 4000) return null

        val ipHeaderLength = (original[0].toInt() and 0x0F) * 4
        if (original.size < ipHeaderLength + 8) return null

        val udpOffset = ipHeaderLength
        val clientAddress = original.copyOfRange(12, 16)
        val clientPort = original.copyOfRange(
            udpOffset,
            udpOffset + 2
        )

        val totalLength = 20 + 8 + dnsResponse.size
        val reply = ByteArray(totalLength)

        reply[0] = 0x45
        reply[1] = 0
        putShort(reply, 2, totalLength)
        putShort(reply, 4, 0)
        putShort(reply, 6, 0x4000)
        reply[8] = 64
        reply[9] = 17

        val dnsAddress = InetAddress.getByName(DNS_ADDRESS).address
        System.arraycopy(dnsAddress, 0, reply, 12, 4)
        System.arraycopy(clientAddress, 0, reply, 16, 4)

        putShort(reply, 10, checksum(reply, 0, 20))

        val udp = 20
        putShort(reply, udp, 53)
        System.arraycopy(clientPort, 0, reply, udp + 2, 2)
        putShort(reply, udp + 4, 8 + dnsResponse.size)
        putShort(reply, udp + 6, 0)

        System.arraycopy(dnsResponse, 0, reply, udp + 8, dnsResponse.size)

        return reply
    }

    private fun putShort(data: ByteArray, offset: Int, value: Int) {
        data[offset] = (value ushr 8).toByte()
        data[offset + 1] = value.toByte()
    }

    private fun checksum(data: ByteArray, offset: Int, length: Int): Int {
        var sum = 0L
        var i = offset

        while (i < offset + length - 1) {
            sum += ((data[i].toInt() and 0xFF) shl 8) or
                (data[i + 1].toInt() and 0xFF)
            i += 2
        }

        if (i < offset + length) {
            sum += (data[i].toInt() and 0xFF) shl 8
        }

        while ((sum ushr 16) != 0L) {
            sum = (sum and 0xFFFF) + (sum ushr 16)
        }

        return sum.inv().toInt() and 0xFFFF
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                Lang.t("Protección DNS de Vesta", "Vesta DNS protection"),
                NotificationManager.IMPORTANCE_LOW
            )
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("Vesta Tracker")
            .setContentText(Lang.t("Protección de dominios activa", "Domain protection active"))
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .build()
    }

    private fun stopVpn() {
        watchdogHandler.removeCallbacks(authorizationWatchdog)
        running.set(false)
        isActive = false

        try {
            tunnel?.close()
        } catch (_: Exception) {
        }

        tunnel = null
        worker?.interrupt()
        worker = null

        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    override fun onRevoke() {
        // Android calls onRevoke when the user disconnects the VPN from
        // Settings or when another app turns on its own VPN. If protection
        // was still authorised, the guardians are notified.
        if (isAuthorized()) {
            BlockAlertReporter.reportTamper(
                this,
                purpose = "domain_filtering",
                key = "vpn_revoked",
                title = Lang.t("Filtro web desactivado", "Web filter turned off"),
                subtitle = Lang.t("Se desconectó la protección DNS de Vesta en el dispositivo.", "Vesta DNS protection was disconnected on the device.")
            )
        }

        stopVpn()
        stopSelf()
        super.onRevoke()
    }

    override fun onDestroy() {
        stopVpn()
        super.onDestroy()
    }
}
