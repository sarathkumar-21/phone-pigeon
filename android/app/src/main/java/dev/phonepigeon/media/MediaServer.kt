package dev.phonepigeon.media

import android.content.Context
import android.graphics.Bitmap
import android.net.ConnectivityManager
import android.os.Build
import android.os.ParcelFileDescriptor
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import android.util.Size
import dev.phonepigeon.crypto.Crypto
import dev.phonepigeon.proto.MediaServerEndpoint
import dev.phonepigeon.storage.MediaRepository
import java.io.BufferedInputStream
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.io.OutputStream
import java.math.BigInteger
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.spec.ECGenParameterSpec
import java.util.Date
import java.util.concurrent.Executors
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.security.auth.x500.X500Principal

/**
 * Plane 2 LAN server (spec v2 §6.2 Mode A, §10.3).
 *
 * - TLS with a self-signed EC certificate whose private key never leaves the Android
 *   Keystore. Its SHA-256 is announced to the Mac inside the E2EE `MediaServerEndpoint`,
 *   so the Mac pins exactly this certificate.
 * - Requests must carry `Authorization: Bearer <nonce.hmac>`, where hmac = HMAC-SHA256(K_media_token, nonce);
 *   only a device holding the pairing secret can mint one. Rotates on every server start.
 * - `GET /media/thumb/{id}`, `GET /media/file?(id|path)=` with HTTP Range (206), `PUT /media/upload?path=`
 *   with SHA-256 verification. Paths are canonicalised under the storage root.
 */
class MediaServer(
    private val context: Context,
    private val mediaKey: ByteArray,
    private val canRead: () -> Boolean = { true },
    private val canWrite: () -> Boolean = { true },
    private val canMirror: () -> Boolean = { true },
) {
    // A bounded pool plus a connection cap: unauthenticated LAN hosts cannot exhaust threads or memory.
    private val pool = Executors.newFixedThreadPool(MAX_CONNECTIONS + 2)
    private val active = java.util.concurrent.atomic.AtomicInteger(0)
    private var server: ServerSocket? = null
    private val nonce = Crypto.randomBytes(16)
    val token: String = b64(nonce) + "." + b64(hmac(nonce))
    var endpoint: MediaServerEndpoint? = null
        private set

    private fun b64(b: ByteArray) = Base64.encodeToString(b, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    private fun hmac(b: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(mediaKey, "HmacSHA256")) }.doFinal(b)

    private fun authorized(header: String?): Boolean {
        val tok = header?.removePrefix("Bearer ")?.trim() ?: return false
        val parts = tok.split('.')
        if (parts.size != 2) return false
        val n = runCatching { Base64.decode(parts[0], Base64.URL_SAFE) }.getOrNull() ?: return false
        return MessageDigest.isEqual(b64(hmac(n)).toByteArray(), parts[1].toByteArray())
    }

    // ------------------------------------------------------------------ lifecycle

    @Synchronized
    fun start(): MediaServerEndpoint? {
        endpoint?.let { return refreshIp(it) }
        return runCatching {
            val (ssl, certHash) = tls()
            val ss = ssl.serverSocketFactory.createServerSocket()
            ss.reuseAddress = true
            runCatching { ss.bind(InetSocketAddress(PORT)) }.onFailure { ss.bind(InetSocketAddress(0)) }
            server = ss
            pool.execute { acceptLoop(ss) }
            MediaServerEndpoint(lanIp(), ss.localPort, token, certHash).also { endpoint = it }
        }.onFailure { Log.w(TAG, "media server failed: ${it.message}") }.getOrNull()
    }

    private fun refreshIp(ep: MediaServerEndpoint) = ep.copy(lanIp = lanIp()).also { endpoint = it }

    @Synchronized
    fun stop() {
        runCatching { server?.close() }
        server = null
        endpoint = null
    }

    /** The phone's Wi-Fi/Ethernet address (never the mobile-data one, which the Mac can't reach). */
    private fun lanIp(): String {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        fun v4(net: android.net.Network?): String? =
            cm?.getLinkProperties(net)?.linkAddresses?.map { it.address }
                ?.firstOrNull { it is Inet4Address && !it.isLoopbackAddress }?.hostAddress
        val local = cm?.allNetworks?.firstOrNull { n ->
            val caps = cm.getNetworkCapabilities(n)
            caps != null && (caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) ||
                caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET)) && v4(n) != null
        }
        return v4(local) ?: v4(cm?.activeNetwork) ?: "0.0.0.0"
    }

    /** Self-signed EC P-256 certificate generated inside the Android Keystore. */
    private fun tls(): Pair<SSLContext, ByteArray> {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!ks.containsAlias(ALIAS)) {
            val gen = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
            gen.initialize(
                KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_NONE)
                    .setCertificateSubject(X500Principal("CN=PhonePigeon Phone"))
                    .setCertificateSerialNumber(BigInteger.valueOf(System.currentTimeMillis()))
                    .setCertificateNotBefore(Date(System.currentTimeMillis() - 86_400_000))
                    .setCertificateNotAfter(Date(System.currentTimeMillis() + 5L * 365 * 86_400_000))
                    .build()
            )
            gen.generateKeyPair()
        }
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        kmf.init(ks, null)
        val ctx = SSLContext.getInstance("TLS")
        ctx.init(kmf.keyManagers, null, null)
        val hash = MessageDigest.getInstance("SHA-256").digest(ks.getCertificate(ALIAS).encoded)
        return ctx to hash
    }

    private fun acceptLoop(ss: ServerSocket) {
        while (!ss.isClosed) {
            val s = runCatching { ss.accept() }.getOrNull() ?: break
            if (active.incrementAndGet() > MAX_CONNECTIONS) { active.decrementAndGet(); runCatching { s.close() }; continue }
            pool.execute { try { serve(s) } finally { active.decrementAndGet() } }
        }
    }

    // ------------------------------------------------------------------ HTTP/1.1

    private class Request(val method: String, val path: String, val query: Map<String, String>, val headers: Map<String, String>)

    private fun serve(socket: Socket) = runCatching {
        socket.tcpNoDelay = true
        runCatching { socket.sendBufferSize = 512 * 1024 }
        socket.use {
            val input = BufferedInputStream(it.getInputStream(), 64 * 1024)
            val out = it.getOutputStream()
            while (true) {
                // Short deadline until the request is read and authorised; relaxed afterwards for large transfers.
                socket.soTimeout = PRE_AUTH_TIMEOUT_MS
                val req = readRequest(input) ?: break
                if (!authorized(req.headers["authorization"])) { respond(out, 401, "text/plain", "unauthorized".toByteArray()); break }
                socket.soTimeout = 60_000
                when {
                    req.method == "GET" && req.path.startsWith("/media/thumb/") -> thumb(req, out)
                    req.method == "GET" && req.path == "/media/file" -> file(req, out)
                    req.method == "GET" && req.path == "/media/screen" -> { screen(out, socket); break }
                    req.method == "PUT" && req.path == "/media/upload" -> upload(req, input, out)
                    else -> respond(out, 404, "text/plain", "not found".toByteArray())
                }
                if (req.headers["connection"]?.equals("close", true) == true) break
            }
        }
    }.onFailure { if (it !is java.net.SocketTimeoutException) Log.d(TAG, "conn: ${it.message}") }

    private fun readLine(input: InputStream): String? {
        val sb = StringBuilder()
        while (true) {
            val b = input.read()
            if (b == -1) return if (sb.isEmpty()) null else sb.toString()
            if (b == '\n'.code) return sb.toString().trimEnd('\r')
            sb.append(b.toChar())
            if (sb.length > 16_384) return null
        }
    }

    private fun readRequest(input: InputStream): Request? {
        val line = readLine(input)?.takeIf { it.isNotBlank() } ?: return null
        val (method, target) = line.split(' ').let { if (it.size < 2) return null else it[0] to it[1] }
        val headers = HashMap<String, String>()
        var headerBytes = 0
        while (true) {
            val h = readLine(input) ?: return null
            if (h.isEmpty()) break
            headerBytes += h.length
            if (headers.size >= 64 || headerBytes > 32 * 1024) return null
            val i = h.indexOf(':')
            if (i > 0) headers[h.substring(0, i).trim().lowercase()] = h.substring(i + 1).trim()
        }
        val path = target.substringBefore('?')
        val query = target.substringAfter('?', "").split('&').filter { it.contains('=') }.associate {
            URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('='), "UTF-8")
        }
        return Request(method, path, query, headers)
    }

    private fun respond(out: OutputStream, code: Int, type: String, body: ByteArray, extra: Map<String, String> = emptyMap()) {
        head(out, code, type, body.size.toLong(), extra)
        out.write(body); out.flush()
    }

    private fun head(out: OutputStream, code: Int, type: String, length: Long, extra: Map<String, String> = emptyMap()) {
        val reason = mapOf(200 to "OK", 201 to "Created", 206 to "Partial Content", 400 to "Bad Request", 401 to "Unauthorized",
            403 to "Forbidden", 404 to "Not Found", 409 to "Conflict", 413 to "Payload Too Large", 416 to "Range Not Satisfiable", 422 to "Unprocessable Entity",
            500 to "Internal Server Error")[code] ?: "OK"
        val sb = StringBuilder("HTTP/1.1 $code $reason\r\nContent-Type: $type\r\nContent-Length: $length\r\nAccept-Ranges: bytes\r\n")
        extra.forEach { (k, v) -> sb.append("$k: $v\r\n") }
        sb.append("\r\n")
        out.write(sb.toString().toByteArray())
    }

    // ------------------------------------------------------------------ routes

    /** 320×320 WebP thumbnails via ContentResolver.loadThumbnail, cached on disk (spec §6.1). */
    private fun thumb(req: Request, out: OutputStream) {
        if (!canRead()) return respond(out, 403, "text/plain", "file access is turned off on the phone".toByteArray())
        val id = req.path.removePrefix("/media/thumb/").toLongOrNull() ?: return respond(out, 400, "text/plain", ByteArray(0))
        val w = req.query["w"]?.toIntOrNull()?.coerceIn(64, 2048) ?: 320
        val h = req.query["h"]?.toIntOrNull()?.coerceIn(64, 2048) ?: 320
        val cache = File(context.cacheDir, "thumbs/${id}_${w}x$h.webp")
        if (!cache.exists()) {
            val bmp = runCatching {
                context.contentResolver.loadThumbnail(MediaRepository.contentUri(id, MediaRepository.mimeOfMedia(context, id)), Size(w, h), null)
            }.getOrNull() ?: return respond(out, 404, "text/plain", ByteArray(0))
            cache.parentFile?.mkdirs()
            cache.outputStream().use { o ->
                @Suppress("DEPRECATION")
                bmp.compress(if (Build.VERSION.SDK_INT >= 30) Bitmap.CompressFormat.WEBP_LOSSY else Bitmap.CompressFormat.WEBP, 78, o)
            }
        }
        respond(out, 200, "image/webp", cache.readBytes(), mapOf("Cache-Control" to "private, max-age=86400"))
    }

    /**
     * Live screen mirror: an open-ended response of length-prefixed H.264 frames.
     * Frame = kind(1) ‖ length(4, BE) ‖ pts µs(8, BE) ‖ Annex-B payload; kind 1 = SPS/PPS, 2 = key, 3 = delta.
     */
    private fun screen(out: OutputStream, socket: Socket) {
        if (!canMirror() || !dev.phonepigeon.screen.ScreenMirror.active) {
            return respond(out, 403, "text/plain", "screen mirroring is not active".toByteArray())
        }
        socket.soTimeout = 0
        val sub = dev.phonepigeon.screen.ScreenMirror.subscribe()
        try {
            out.write("HTTP/1.1 200 OK\r\nContent-Type: application/x-phonepigeon-screen\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".toByteArray())
            dev.phonepigeon.screen.ScreenMirror.currentConfig()?.let { writeFrame(out, 1, 0, it) }
            while (!sub.closed && canMirror()) {
                val f = sub.queue.poll(2, java.util.concurrent.TimeUnit.SECONDS)
                if (f == null) { out.flush(); continue }
                if (sub.closed || f.kind == 0.toByte()) break
                writeFrame(out, f.kind.toInt(), f.ptsUs, f.data)
                if (sub.queue.isEmpty()) out.flush()
            }
        } finally {
            dev.phonepigeon.screen.ScreenMirror.unsubscribe(sub)
        }
    }

    private fun writeFrame(out: OutputStream, kind: Int, pts: Long, data: ByteArray) {
        val h = java.nio.ByteBuffer.allocate(13).put(kind.toByte()).putInt(data.size).putLong(pts).array()
        out.write(h); out.write(data)
    }

    /** Full file with HTTP Range → 206 Partial Content for instant AVPlayer seeking (spec §6.2). */
    private fun file(req: Request, out: OutputStream) {
        if (!canRead()) return respond(out, 403, "text/plain", "file access is turned off on the phone".toByteArray())
        val pfd: ParcelFileDescriptor
        val type: String
        val id = req.query["id"]?.toLongOrNull()
        if (id != null) {
            val mime = MediaRepository.mimeOfMedia(context, id) ?: return respond(out, 404, "text/plain", ByteArray(0))
            pfd = runCatching { context.contentResolver.openFileDescriptor(MediaRepository.contentUri(id, mime), "r") }.getOrNull()
                ?: return respond(out, 404, "text/plain", ByteArray(0))
            type = mime
        } else {
            val f = MediaRepository.resolve(req.query["path"] ?: "") ?: return respond(out, 403, "text/plain", "outside storage".toByteArray())
            if (!f.isFile) return respond(out, 404, "text/plain", ByteArray(0))
            pfd = ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY)
            type = MediaRepository.mimeOf(f.name)
        }
        pfd.use { d ->
            FileInputStream(d.fileDescriptor).use { fis ->
                val ch = fis.channel
                val total = ch.size()
                val range = req.headers["range"]?.let(::parseRange)
                val extra = HashMap<String, String>()
                // TLS already authenticates every byte, so a SHA-256 is only computed when the client asks for it
                // (`X-Want-SHA256: 1`): hashing before sending would read the whole file twice.
                if (range == null && req.headers["x-want-sha256"] == "1" && total <= 64L * 1024 * 1024) {
                    val md = MessageDigest.getInstance("SHA-256")
                    val buf = java.nio.ByteBuffer.allocate(1 shl 16)
                    ch.position(0)
                    while (ch.read(buf) > 0) { buf.flip(); md.update(buf); buf.clear() }
                    extra["X-Content-SHA256"] = md.digest().joinToString("") { "%02x".format(it) }
                }
                val (start, end) = if (range != null) {
                    val s = range.first ?: (total - (range.second ?: 0))
                    val e = if (range.first == null) total - 1 else minOf(range.second ?: (total - 1), total - 1)
                    if (s < 0 || s > e || s >= total) {
                        head(out, 416, "text/plain", 0, mapOf("Content-Range" to "bytes */$total")); out.flush(); return
                    }
                    s to e
                } else 0L to total - 1
                val length = end - start + 1
                if (range != null) extra["Content-Range"] = "bytes $start-$end/$total"
                head(out, if (range != null) 206 else 200, type, length, extra)
                ch.position(start)
                val buf = ByteArray(1 shl 18)
                var left = length
                while (left > 0) {
                    val n = fis.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
                    if (n <= 0) break
                    out.write(buf, 0, n); left -= n
                }
                out.flush()
            }
        }
    }

    private fun parseRange(h: String): Pair<Long?, Long?>? {
        val spec = h.removePrefix("bytes=").substringBefore(',').trim()
        val (a, b) = spec.split('-').let { if (it.size != 2) return null else it[0] to it[1] }
        return a.toLongOrNull() to b.toLongOrNull()
    }

    /** Upload from the Mac; written to `.part`, SHA-256 verified, then atomically renamed and media-scanned. */
    private fun upload(req: Request, input: InputStream, out: OutputStream) {
        if (!canWrite()) return respond(out, 403, "text/plain", "uploads are turned off on the phone".toByteArray())
        val dest = MediaRepository.resolve(req.query["path"] ?: "") ?: return respond(out, 403, "text/plain", "outside storage".toByteArray())
        if (!MediaRepository.hasAllFilesAccess()) return respond(out, 403, "text/plain", "All files access not granted".toByteArray())
        val length = req.headers["content-length"]?.toLongOrNull()
        val chunked = req.headers["transfer-encoding"]?.contains("chunked", true) == true
        if (length == null && !chunked) return respond(out, 400, "text/plain", "missing length".toByteArray())
        // Never accept more than the free space (minus a safety margin) or an absolute cap.
        val budget = minOf(MAX_UPLOAD_BYTES, (MediaRepository.root.usableSpace - 256L * 1024 * 1024).coerceAtLeast(0))
        if (length != null && (length < 0 || length > budget)) return respond(out, 413, "text/plain", "too large for the free space on the phone".toByteArray())
        dest.parentFile?.mkdirs()
        val part = File(dest.parentFile, ".${dest.name}.part")
        val md = MessageDigest.getInstance("SHA-256")
        var received = 0L
        try {
            java.io.BufferedOutputStream(part.outputStream(), 256 * 1024).use { o ->
                fun copy(n: Long) {
                    val buf = ByteArray(1 shl 18)
                    var left = n
                    while (left > 0) {
                        val r = input.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
                        if (r <= 0) throw java.io.EOFException()
                        received += r
                        if (received > budget) throw java.io.IOException("upload exceeds the allowed size")
                        o.write(buf, 0, r); md.update(buf, 0, r); left -= r
                    }
                }
                if (chunked) {
                    while (true) {
                        val size = readLine(input)?.substringBefore(';')?.trim()?.toLongOrNull(16) ?: break
                        if (size < 0) throw java.io.IOException("bad chunk")
                        if (size == 0L) { readLine(input); break }
                        copy(size); readLine(input)
                    }
                } else copy(length!!)
            }
        } catch (e: Exception) {
            part.delete() // never leave a half-written hidden file behind
            if (e is java.io.IOException && e.message?.contains("exceeds") == true) return respond(out, 413, "text/plain", "too large".toByteArray())
            throw e
        }
        val digest = md.digest().joinToString("") { "%02x".format(it) }
        val expected = req.headers["x-content-sha256"]?.lowercase()
        if (expected != null && expected != digest) {
            part.delete()
            return respond(out, 422, "text/plain", "sha256 mismatch".toByteArray())
        }
        val target = if (dest.exists()) uniqueName(dest) else dest
        if (!part.renameTo(target)) { part.delete(); return respond(out, 500, "text/plain", "write failed".toByteArray()) }
        MediaRepository.scan(context, target)
        val relPath = MediaRepository.relative(target).replace("\\", "\\\\").replace("\"", "\\\"")
        respond(out, 201, "application/json", """{"path":"$relPath","sha256":"$digest"}""".toByteArray())
    }

    private fun uniqueName(f: File): File {
        var i = 1
        var c: File
        do { c = File(f.parentFile, "${f.nameWithoutExtension} ($i)" + if (f.extension.isEmpty()) "" else ".${f.extension}"); i++ } while (c.exists())
        return c
    }

    companion object {
        const val PORT = 8444
        private const val MAX_CONNECTIONS = 16
        private const val PRE_AUTH_TIMEOUT_MS = 8_000
        private const val MAX_UPLOAD_BYTES = 16L * 1024 * 1024 * 1024
        private const val ALIAS = "phonepigeon-media-tls"
        private const val TAG = "PhonePigeon"
    }
}
