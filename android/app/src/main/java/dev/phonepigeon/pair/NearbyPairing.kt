package dev.phonepigeon.pair

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Base64
import android.util.Log
import dev.phonepigeon.crypto.Crypto
import dev.phonepigeon.proto.PairingQrPayload
import dev.phonepigeon.service.RelayEngine
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest

/**
 * "Find my phone from the Mac": while the pairing screen is open, this phone is visible to PhonePigeon on the same
 * Wi-Fi (Bonjour `_pigeonphone._tcp`) so the Mac can offer it in its Add Phone list instead of a QR scan.
 *
 * Safety: the phone is only visible while this screen is open and unpaired. A network neighbour could pose as the
 * Mac, so nothing is trusted until a six-digit code shown on BOTH screens is confirmed by the user on BOTH devices.
 * The Mac commits to its key before it sees the phone's (commit-reveal), so an attacker in the middle cannot pick
 * keys that make the two codes match. After confirmation the normal encrypted pairing handshake runs, with its
 * secret derived from the confirmed exchange.
 */
object NearbyPairing {
    sealed interface State {
        data object Idle : State
        data object Visible : State
        data class Confirm(val macName: String, val code: String) : State
        data object Finishing : State
        data class Failed(val message: String) : State
    }

    private const val TAG = "PhonePigeon"
    private const val SERVICE_TYPE = "_pigeonphone._tcp"
    private const val MAX_MESSAGE = 4096

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()

    private var server: ServerSocket? = null
    private var nsd: NsdManager? = null
    private var registration: NsdManager.RegistrationListener? = null
    @Volatile private var decision: CompletableDeferred<Boolean>? = null
    @Volatile private var busy = false

    // ------------------------------------------------------------------ wire messages

    @Serializable private data class Hello(val type: String = "hello", val v: Int, val commit: String, @SerialName("mac_name") val macName: String = "")
    @Serializable private data class Offer(
        val type: String = "offer", val v: Int = 1,
        @SerialName("android_device_id") val deviceId: String,
        @SerialName("android_pub_key") val pubKey: String,
        @SerialName("device_name") val deviceName: String,
        val manufacturer: String, @SerialName("os_version") val osVersion: String,
    )
    @Serializable private data class Reveal(
        val type: String = "reveal",
        @SerialName("mac_device_id") val macDeviceId: String,
        @SerialName("mac_pub_key") val macPubKey: String,
        val nonce: String,
        @SerialName("session_id") val sessionId: String,
        @SerialName("relay_url") val relayUrl: String = "",
        @SerialName("lan_host") val lanHost: String? = null,
        @SerialName("mac_name") val macName: String = "",
    )
    @Serializable private data class Decision(val type: String = "decision", val accepted: Boolean)

    // ------------------------------------------------------------------ lifecycle

    @Synchronized
    fun start(context: Context) {
        if (server != null) return
        val app = context.applicationContext
        val engine = RelayEngine.get(app)
        if (engine.store.pairing != null) return // already paired: stay invisible
        val ss = runCatching { ServerSocket(0) }.getOrElse { _state.value = State.Failed("Couldn't open a local port."); return }
        server = ss
        _state.value = State.Visible
        scope.launch { acceptLoop(ss, app) }

        val manager = app.getSystemService(NsdManager::class.java)
        nsd = manager
        val info = NsdServiceInfo().apply {
            serviceName = "PhonePigeon · ${deviceName()}"
            serviceType = SERVICE_TYPE
            port = ss.localPort
            setAttribute("v", "1")
            setAttribute("model", Build.MODEL.take(40))
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(i: NsdServiceInfo) { Log.i(TAG, "visible to Macs as ${i.serviceName}") }
            override fun onRegistrationFailed(i: NsdServiceInfo, code: Int) { Log.w(TAG, "nearby registration failed $code") }
            override fun onServiceUnregistered(i: NsdServiceInfo) {}
            override fun onUnregistrationFailed(i: NsdServiceInfo, code: Int) {}
        }
        registration = listener
        runCatching { manager?.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener) }
            .onFailure { Log.w(TAG, "nearby advertise failed: ${it.message}") }
    }

    @Synchronized
    fun stop() {
        runCatching { registration?.let { nsd?.unregisterService(it) } }
        registration = null
        runCatching { server?.close() }
        server = null
        decision?.complete(false)
        decision = null
        busy = false
        _state.value = State.Idle
    }

    /** The user's answer on the confirmation dialog. */
    fun decide(accept: Boolean) { Log.i(TAG, "user decision: $accept"); decision?.complete(accept) }

    fun dismissFailure() { if (_state.value is State.Failed) _state.value = if (server != null) State.Visible else State.Idle }

    private fun deviceName(): String =
        if (Build.MODEL.startsWith(Build.MANUFACTURER, ignoreCase = true)) Build.MODEL else "${Build.MANUFACTURER} ${Build.MODEL}"

    // ------------------------------------------------------------------ protocol

    private fun acceptLoop(ss: ServerSocket, app: Context) {
        while (!ss.isClosed) {
            val s = runCatching { ss.accept() }.getOrNull() ?: break
            if (busy) { runCatching { s.close() }; continue } // one pairing attempt at a time
            busy = true
            scope.launch { try { handle(s, app) } finally { busy = false; runCatching { s.close() } } }
        }
    }

    private fun read(input: DataInputStream): String {
        val len = input.readInt()
        require(len in 1..MAX_MESSAGE) { "bad message size" }
        return String(ByteArray(len).also { input.readFully(it) })
    }

    private fun write(out: DataOutputStream, text: String) {
        val b = text.toByteArray()
        out.writeInt(b.size); out.write(b); out.flush()
    }

    private fun sha256(vararg parts: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").also { md -> parts.forEach(md::update) }.digest()

    private suspend fun handle(socket: Socket, app: Context) {
        val engine = RelayEngine.get(app)
        try {
            socket.soTimeout = 20_000
            val input = DataInputStream(socket.getInputStream().buffered())
            val out = DataOutputStream(socket.getOutputStream().buffered())

            // 1. The Mac commits to its key (it has not seen ours yet).
            Log.i(TAG, "nearby: connection from ${socket.inetAddress}")
            val hello = json.decodeFromString(Hello.serializer(), read(input))
            require(hello.type == "hello" && hello.v == 1) { "unexpected hello" }
            val commit = Base64.decode(hello.commit, Base64.NO_WRAP)
            require(commit.size == 32) { "bad commitment" }

            // 2. We reveal ours.
            val pub = engine.store.publicKey
            write(out, json.encodeToString(Offer.serializer(), Offer(
                deviceId = engine.store.deviceId, pubKey = Base64.encodeToString(pub, Base64.NO_WRAP), deviceName = deviceName(),
                manufacturer = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }, osVersion = "Android ${Build.VERSION.RELEASE}")))

            // 3. The Mac reveals its key; it must match the commitment, or we stop.
            val reveal = json.decodeFromString(Reveal.serializer(), read(input))
            val macPub = Base64.decode(reveal.macPubKey, Base64.NO_WRAP)
            val nonce = Base64.decode(reveal.nonce, Base64.NO_WRAP)
            require(macPub.size == 32 && nonce.size == 32 && reveal.sessionId.length in 16..64 && reveal.macDeviceId.isNotBlank()) { "bad reveal" }
            val expected = sha256("phonepigeon-nearby-commit-v1".toByteArray(), macPub, nonce, reveal.sessionId.toByteArray())
            require(MessageDigest.isEqual(expected, commit)) { "key does not match the commitment" }

            // 4. Both screens show the same code; both users must confirm it.
            val sasBytes = sha256("phonepigeon-sas-v1".toByteArray(), reveal.sessionId.toByteArray(), macPub, pub)
            val number = ((sasBytes[0].toLong() and 0xFF) shl 24 or ((sasBytes[1].toLong() and 0xFF) shl 16) or
                ((sasBytes[2].toLong() and 0xFF) shl 8) or (sasBytes[3].toLong() and 0xFF)) % 1_000_000
            val code = "%06d".format(number).let { "${it.take(3)} ${it.drop(3)}" }
            Log.i(TAG, "nearby: waiting for the user to confirm code $code")
            val wait = CompletableDeferred<Boolean>().also { decision = it }
            _state.value = State.Confirm(reveal.macName.ifBlank { hello.macName.ifBlank { "Your Mac" } }, code)

            val mine = withTimeoutOrNull(120_000) { wait.await() } ?: false
            write(out, json.encodeToString(Decision.serializer(), Decision(accepted = mine)))
            if (!mine) { _state.value = State.Visible; return }

            socket.soTimeout = 120_000
            val theirs = json.decodeFromString(Decision.serializer(), read(input)).accepted
            if (!theirs) { _state.value = State.Failed("The Mac cancelled."); return }

            // 5. Run the normal encrypted pairing with a secret both sides derived from this confirmed exchange.
            _state.value = State.Finishing
            val secret = Crypto.hkdf(sha256("phonepigeon-nearby-v1".toByteArray(), reveal.sessionId.toByteArray(), macPub, pub, nonce),
                ByteArray(0), "pairing-secret".toByteArray())
            val qr = PairingQrPayload(v = 2, sessionId = reveal.sessionId, macDeviceId = reveal.macDeviceId, macPubKey = reveal.macPubKey,
                relayUrl = reveal.relayUrl, lanHost = reveal.lanHost, macName = reveal.macName.ifBlank { null },
                pairingSecret = Base64.encodeToString(secret, Base64.NO_WRAP))
            engine.pair(qr)
                .onSuccess { _state.value = State.Idle }
                .onFailure { _state.value = State.Failed(it.message ?: "Pairing failed") }
        } catch (e: Exception) {
            Log.w(TAG, "nearby pairing stopped: ${e.javaClass.simpleName} ${e.message}", e)
            if (_state.value is State.Confirm || _state.value is State.Finishing) _state.value = State.Failed("Pairing was interrupted. Try again from your Mac.")
            else if (server != null) _state.value = State.Visible
        } finally {
            decision = null
        }
    }
}
