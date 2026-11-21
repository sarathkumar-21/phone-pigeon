package dev.phonepigeon.network

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import dev.phonepigeon.proto.WireCodec
import dev.phonepigeon.proto.WireFrame
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume

enum class LinkState { IDLE, CONNECTING, CONNECTED }

interface FrameTransport {
    val state: LinkState
    var onFrame: (WireFrame) -> Unit
    var onState: (LinkState) -> Unit
    fun start()
    fun stop()
    fun send(frame: WireFrame): Boolean
}

private fun encode(frame: WireFrame) = WireCodec.json.encodeToString(WireFrame.serializer(), frame).toByteArray()
private fun decode(bytes: ByteArray) = runCatching { WireCodec.json.decodeFromString(WireFrame.serializer(), bytes.decodeToString()) }.getOrNull()

/**
 * Local-network transport (spec §2, priority 1). The Mac listens and advertises
 * `_pigeonmac._tcp` with a hashed `h` TXT tag; the phone discovers it via NSD
 * (falling back to the `lan_host` from the QR code) and keeps a TCP link open.
 * Frames are 4-byte big-endian length-prefixed JSON; every payload inside is an
 * E2EE envelope, so the socket itself carries no plaintext.
 */
class LanClient(
    private val context: Context,
    private val macDeviceId: String,
    private var fallbackHost: String?,
    private val onHostDiscovered: (String) -> Unit,
) : FrameTransport {
    override var state = LinkState.IDLE
        private set(v) { if (field != v) { field = v; onState(v) } }
    override var onFrame: (WireFrame) -> Unit = {}
    override var onState: (LinkState) -> Unit = {}
    var connectedHost: String? = null
        private set

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var job: Job? = null
    @Volatile private var out: DataOutputStream? = null
    @Volatile private var socket: Socket? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun start() {
        if (job?.isActive == true) return
        multicastLock = context.getSystemService(WifiManager::class.java)
            ?.createMulticastLock("phonepigeon-nsd")?.apply { setReferenceCounted(false); acquire() }
        job = scope.launch {
            var failures = 0
            while (isActive) {
                state = LinkState.CONNECTING
                // Known address first (instant). Bonjour only after it failed twice, e.g. the Mac got a new IP.
                val known = fallbackHost
                var reached = false
                if (known != null) reached = attempt(known)
                if (!reached && (known == null || failures >= 1)) {
                    discover()?.let { reached = attempt(it) }
                }
                failures = if (reached) 0 else failures + 1
                state = LinkState.IDLE
                connectedHost = null
                // A link that was up (the Mac restarted, Wi-Fi blipped) retries after one second; a Mac that is
                // simply absent is retried every few seconds, never backing off to half a minute.
                delay(if (reached) 1000L else (1500L * failures).coerceAtMost(5000L))
            }
        }
    }

    /** Runs one session; true if it ever connected, however it ended (a reset after a Mac restart still counts). */
    private fun attempt(host: String): Boolean {
        reachedConnected = false
        runCatching { session(host) }
        return reachedConnected
    }

    @Volatile private var reachedConnected = false

    override fun stop() {
        job?.cancel()
        runCatching { socket?.close() }
        multicastLock?.release()
        state = LinkState.IDLE
    }

    /** Single writer thread: callers (BroadcastReceivers, main thread) must never touch the socket directly. */
    private val writer = java.util.concurrent.Executors.newSingleThreadExecutor()

    override fun send(frame: WireFrame): Boolean {
        val o = out ?: return false
        val bytes = encode(frame)
        writer.execute {
            runCatching { synchronized(o) { o.writeInt(bytes.size); o.write(bytes); o.flush() } }
                .onFailure { Log.w("PhonePigeon", "LAN write failed: ${it.message}"); runCatching { socket?.close() } }
        }
        return true
    }

    /** One-shot connect used during pairing, before NSD knows who to look for. */
    suspend fun sendOnce(host: String, frame: WireFrame): Boolean = withTimeoutOrNull(6000) {
        runCatching {
            val (h, p) = split(host)
            Socket().use { s ->
                s.connect(InetSocketAddress(h, p), 4000)
                val o = DataOutputStream(s.getOutputStream())
                val bytes = encode(frame)
                o.writeInt(bytes.size); o.write(bytes); o.flush()
                delay(300)
            }
        }.isSuccess
    } ?: false

    private fun split(host: String): Pair<String, Int> {
        val i = host.lastIndexOf(':')
        return if (i > 0) host.substring(0, i) to host.substring(i + 1).toInt() else host to 8443
    }

    private fun session(host: String) {
        val (h, p) = split(host)
        val s = Socket()
        s.tcpNoDelay = true
        s.keepAlive = true
        s.connect(InetSocketAddress(h, p), 3000)
        // A Mac that quit, slept or changed network leaves a half-open socket that Android would keep for hours.
        // Ping every 15 s (a zero-length frame); the Mac echoes it, so 40 s of silence means the link is dead.
        s.soTimeout = 40_000
        socket = s
        val o = DataOutputStream(s.getOutputStream())
        out = o
        connectedHost = host
        reachedConnected = true
        state = LinkState.CONNECTED
        val pinger = scope.launch {
            while (isActive) {
                delay(15_000)
                writer.execute { runCatching { synchronized(o) { o.writeInt(0); o.flush() } }.onFailure { runCatching { s.close() } } }
            }
        }
        try {
            val input = DataInputStream(s.getInputStream())
            while (true) {
                val len = input.readInt()
                if (len == 0) continue // keep-alive echo
                if (len < 0 || len > 8 * 1024 * 1024) break
                val buf = ByteArray(len)
                input.readFully(buf)
                decode(buf)?.let(onFrame)
            }
        } finally {
            pinger.cancel()
            out = null
            runCatching { s.close() }
        }
    }

    /** NSD discovery of the paired Mac, matched by TXT `device_id`. */
    private suspend fun discover(): String? = withTimeoutOrNull(6000) {
        val nsd = context.getSystemService(NsdManager::class.java) ?: return@withTimeoutOrNull null
        suspendCancellableCoroutine { cont ->
            var done = false
            lateinit var listener: NsdManager.DiscoveryListener
            fun finish(v: String?) {
                if (done) return
                done = true
                runCatching { nsd.stopServiceDiscovery(listener) }
                if (cont.isActive) cont.resume(v)
            }
            listener = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(t: String) {}
                override fun onDiscoveryStopped(t: String) {}
                override fun onStartDiscoveryFailed(t: String, e: Int) = finish(null)
                override fun onStopDiscoveryFailed(t: String, e: Int) {}
                override fun onServiceLost(info: NsdServiceInfo) {}
                override fun onServiceFound(info: NsdServiceInfo) {
                    @Suppress("DEPRECATION")
                    nsd.resolveService(info, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(i: NsdServiceInfo, e: Int) {}
                        override fun onServiceResolved(i: NsdServiceInfo) {
                            val tag = i.attributes["h"]?.decodeToString()
                            if (tag != dev.phonepigeon.crypto.Crypto.mdnsTag(macDeviceId)) return
                            val addr = if (Build.VERSION.SDK_INT >= 34) i.hostAddresses.firstOrNull() else @Suppress("DEPRECATION") i.host
                            val hostPort = "${addr?.hostAddress}:${i.port}"
                            fallbackHost = hostPort
                            onHostDiscovered(hostPort)
                            finish(hostPort)
                        }
                    })
                }
            }
            runCatching { nsd.discoverServices("_pigeonmac._tcp", NsdManager.PROTOCOL_DNS_SD, listener) }.onFailure { finish(null) }
            cont.invokeOnCancellation { runCatching { nsd.stopServiceDiscovery(listener) } }
        }
    }
}

/**
 * Cloud relay transport (spec §10): X25519 proof-of-possession registration → JWT → WebSocket.
 * During pairing it also redeems the QR's `session_id`, which links this phone to that Mac on the relay.
 */
class RelayClient(
    private val wsUrl: String,
    private val deviceId: String,
    private val privateKey: ByteArray,
    private var pairingSessionId: String? = null,
) : FrameTransport {
    override var state = LinkState.IDLE
        private set(v) { if (field != v) { field = v; onState(v) } }
    override var onFrame: (WireFrame) -> Unit = {}
    override var onState: (LinkState) -> Unit = {}

    private val http = OkHttpClient.Builder().pingInterval(25, TimeUnit.SECONDS).build()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var ws: WebSocket? = null
    private var job: Job? = null
    private var token: String? = null

    @Serializable private data class ChallengeReq(@SerialName("device_id") val deviceId: String, val platform: String = "ANDROID",
                                                  @SerialName("public_key") val publicKey: String)
    @Serializable private data class ChallengeRes(@SerialName("challenge_id") val challengeId: String,
                                                  @SerialName("server_public_key") val serverPublicKey: String, val nonce: String)
    @Serializable private data class RegisterReq(@SerialName("challenge_id") val challengeId: String, val proof: String)
    @Serializable private data class RegisterRes(val token: String)
    @Serializable private data class SessionReq(@SerialName("session_id") val sessionId: String)

    private val restBase get() = wsUrl.replaceFirst("wss://", "https://").replaceFirst("ws://", "http://").substringBefore("/v1/")
    private val json = WireCodec.json
    private val jsonType = "application/json".toMediaType()
    private fun b64(b: ByteArray) = android.util.Base64.encodeToString(b, android.util.Base64.NO_WRAP)
    private fun unb64(s: String) = android.util.Base64.decode(s, android.util.Base64.DEFAULT)

    override fun start() {
        if (job?.isActive == true) return
        job = scope.launch {
            var backoff = 2000L
            while (isActive) {
                state = LinkState.CONNECTING
                val ok = runCatching { connect() }.onFailure { Log.d("PhonePigeon", "relay: ${it.message}") }.getOrDefault(false)
                if (ok) backoff = 2000L
                state = LinkState.IDLE
                delay(backoff)
                backoff = (backoff * 2).coerceAtMost(60_000)
            }
        }
    }

    private fun postJson(path: String, body: String, auth: Boolean = false): String {
        val req = Request.Builder().url("$restBase$path").post(body.toRequestBody(jsonType))
        if (auth) req.header("Authorization", "Bearer $token")
        http.newCall(req.build()).execute().use { r ->
            val text = r.body?.string().orEmpty()
            if (r.code == 401) token = null
            check(r.isSuccessful) { "$path → ${r.code} $text" }
            return text
        }
    }

    /** proof = HMAC-SHA256(X25519(sk, server_eph), "phonepigeon-register-v1" ‖ device_id ‖ nonce). */
    private fun register(): String {
        val pub = dev.phonepigeon.crypto.Crypto.publicKey(privateKey)
        val ch = json.decodeFromString(ChallengeRes.serializer(),
            postJson("/v1/devices/challenge", json.encodeToString(ChallengeReq.serializer(), ChallengeReq(deviceId, publicKey = b64(pub)))))
        val shared = dev.phonepigeon.crypto.Crypto.sharedSecret(privateKey, unb64(ch.serverPublicKey))
        val mac = javax.crypto.Mac.getInstance("HmacSHA256").apply { init(javax.crypto.spec.SecretKeySpec(shared, "HmacSHA256")) }
        mac.update("phonepigeon-register-v1".toByteArray()); mac.update(deviceId.toByteArray()); mac.update(unb64(ch.nonce))
        val res = postJson("/v1/devices/register", json.encodeToString(RegisterReq.serializer(), RegisterReq(ch.challengeId, b64(mac.doFinal()))))
        return json.decodeFromString(RegisterRes.serializer(), res).token
    }

    private suspend fun connect(): Boolean {
        if (token == null) token = register()
        pairingSessionId?.let { sid ->
            postJson("/v1/pairings", json.encodeToString(SessionReq.serializer(), SessionReq(sid)), auth = true)
            pairingSessionId = null
        }
        return suspendCancellableCoroutine { cont ->
            ws = http.newWebSocket(Request.Builder().url(wsUrl).header("Authorization", "Bearer $token").build(),
                object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) { state = LinkState.CONNECTED }
                    override fun onMessage(webSocket: WebSocket, text: String) { decode(text.toByteArray())?.let(onFrame) }
                    override fun onMessage(webSocket: WebSocket, bytes: ByteString) { decode(bytes.toByteArray())?.let(onFrame) }
                    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { if (cont.isActive) cont.resume(true) }
                    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                        if (response?.code == 401) token = null
                        if (cont.isActive) cont.resume(false)
                    }
                })
            cont.invokeOnCancellation { ws?.cancel() }
        }
    }

    override fun stop() {
        job?.cancel()
        ws?.close(1000, null)
        state = LinkState.IDLE
    }

    override fun send(frame: WireFrame): Boolean =
        state == LinkState.CONNECTED && (ws?.send(ByteString.of(*encode(frame))) ?: false)
}
