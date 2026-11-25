package dev.phonepigeon.service

import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Base64
import android.util.Log
import androidx.core.content.ContextCompat
import dev.phonepigeon.crypto.Crypto
import dev.phonepigeon.crypto.SecureChannel
import dev.phonepigeon.crypto.SessionKeys
import dev.phonepigeon.data.Pairing
import dev.phonepigeon.data.PairingStore
import dev.phonepigeon.network.LanClient
import dev.phonepigeon.network.LinkState
import dev.phonepigeon.network.RelayClient
import dev.phonepigeon.proto.CallState
import dev.phonepigeon.proto.CallStateEvent
import dev.phonepigeon.proto.ContactSyncBatch
import dev.phonepigeon.proto.MessageDirection
import dev.phonepigeon.proto.MessageStatus
import dev.phonepigeon.proto.PairAckBody
import dev.phonepigeon.proto.PairAckEnvelope
import dev.phonepigeon.proto.PairingQrPayload
import dev.phonepigeon.proto.PayloadBody
import dev.phonepigeon.proto.SimCard
import dev.phonepigeon.proto.SimInventorySync
import dev.phonepigeon.proto.SmsMessageEvent
import dev.phonepigeon.proto.SmsStatusUpdate
import dev.phonepigeon.proto.SmsThreadSync
import dev.phonepigeon.proto.WireCodec
import dev.phonepigeon.proto.WireFrame
import dev.phonepigeon.telephony.CallController
import dev.phonepigeon.telephony.ContactsReader
import dev.phonepigeon.telephony.DeviceStatusReader
import dev.phonepigeon.telephony.SimInventory
import dev.phonepigeon.telephony.SmsRepository
import dev.phonepigeon.telephony.has
import dev.phonepigeon.media.MediaServer
import dev.phonepigeon.storage.MediaRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

enum class Connection(val label: String) { OFFLINE("Offline"), CONNECTING("Connecting…"), LAN("Local network"), CLOUD("Cloud relay") }

enum class ActivityKind { SMS_IN, SMS_OUT, CALL, SYNC, ERROR, LINK }
data class Activity(val kind: ActivityKind, val text: String, val at: Long = System.currentTimeMillis())

data class EngineState(
    val paired: Boolean = false,
    val macName: String = "",
    val connection: Connection = Connection.OFFLINE,
    val lanHost: String? = null,
    val sims: List<SimCard> = emptyList(),
    val relayed: Int = 0,
    val activity: List<Activity> = emptyList(),
    val myFingerprint: String = "",
    val macFingerprint: String = "",
    val pairedAt: Long = 0,
    val shareSms: Boolean = true,
    val shareCalls: Boolean = true,
    val shareContacts: Boolean = true,
    val filesRead: Boolean = true,
    val filesWrite: Boolean = true,
    val filesDelete: Boolean = false,
    val screenMirror: Boolean = true,
    val shareNotifications: Boolean = true,
    val remoteControl: Boolean = false,
    val activeCall: CallStateEvent? = null,
)

/**
 * The phone side of the relay. Owns the secure channel, transports and the
 * telephony bridges; exposes a StateFlow for the UI and the status notification.
 */
class RelayEngine private constructor(private val app: Context) {
    companion object {
        @Volatile private var instance: RelayEngine? = null
        fun get(context: Context) = instance ?: synchronized(this) {
            instance ?: RelayEngine(context.applicationContext).also { instance = it }
        }
    }

    val store = PairingStore(app)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val _state = MutableStateFlow(EngineState())
    val state: StateFlow<EngineState> = _state.asStateFlow()

    private var channel: SecureChannel? = null
    private var lan: LanClient? = null
    private var relay: RelayClient? = null
    private var calls: CallController? = null
    private var heartbeat: Job? = null
    private var mediaServer: MediaServer? = null
    private val outbox = ArrayDeque<PayloadBody>()
    private var running = false
    @Volatile private var pairConfirmation: kotlinx.coroutines.CompletableDeferred<Unit>? = null

    init {
        refreshState()
        dev.phonepigeon.screen.ScreenMirror.statusSink = { st -> send(PayloadBody(screenStatus = st), queueIfOffline = false) }
        dev.phonepigeon.screen.ScreenMirror.controlAvailable = { store.allowRemoteControl && RemoteControlService.instance != null }
    }

    // ------------------------------------------------------------------ pairing (spec §5.1)

    /** Parses the Mac's QR payload, derives keys and delivers a sealed PairAck. */
    /** Parses and validates a pairing code without acting on it; the UI shows it for confirmation first. */
    fun parseQr(qrText: String): Result<PairingQrPayload> = runCatching {
        val qr = runCatching { WireCodec.json.decodeFromString(PairingQrPayload.serializer(), qrText.trim()) }
            .getOrElse { error("That isn't a PhonePigeon pairing code.") }
        require(qr.v == 2) { "This code is from an incompatible PhonePigeon version. Update both apps." }
        require(Base64.decode(qr.macPubKey, Base64.DEFAULT).size == 32) { "Invalid Mac public key" }
        require(Base64.decode(qr.pairingSecret, Base64.DEFAULT).size == 32) { "Invalid pairing secret" }
        require(qr.sessionId.length in 16..64 && qr.macDeviceId.isNotBlank()) { "Invalid pairing code" }
        qr
    }

    suspend fun pair(qr: PairingQrPayload): Result<String> = withContext(Dispatchers.IO) {
        Log.i("PhonePigeon", "pairing started for session ${qr.sessionId.take(8)}")
        runCatching {
            val macKey = Base64.decode(qr.macPubKey, Base64.DEFAULT)
            val secret = Base64.decode(qr.pairingSecret, Base64.DEFAULT)

            val keys = SessionKeys.derive(store.privateKey, macKey, qr.sessionId)
            val proof = Crypto.pairProof(secret, qr.sessionId, store.publicKey, macKey)
            val body = PairAckBody(qr.sessionId, deviceName(), Build.MANUFACTURER.replaceFirstChar { it.uppercase() },
                "Android ${Build.VERSION.RELEASE}", Base64.encodeToString(proof, Base64.NO_WRAP))
            val (nonce, ct) = SecureChannel.sealPairAck(body, keys)
            val ack = WireFrame(pairAck = PairAckEnvelope(qr.sessionId, store.deviceId, store.publicKey, nonce, ct))

            stop()
            store.incomingSequence = 0
            channel = SecureChannel(keys, qr.sessionId, store.deviceId, qr.macDeviceId, store.outgoingSequence, 0)
            val confirmed = kotlinx.coroutines.CompletableDeferred<Unit>()
            pairConfirmation = confirmed
            val pairing = Pairing(qr.sessionId, qr.macDeviceId, macKey, qr.relayUrl, qr.lanHost, System.currentTimeMillis(),
                qr.macName ?: "Mac")

            // Deliver PairAck over the LAN link (it stays open for the session that follows).
            val link = buildLan(pairing)
            link.start()
            val connected = withTimeoutOrNull(20_000) { linkState.first { it == LinkState.CONNECTED } } != null
            val delivered = connected && link.send(ack)
            if (!delivered && !relayConfigured(pairing.relayUrl)) {
                link.stop(); channel = null
                error("Couldn't reach your Mac${qr.lanHost?.let { " at $it" } ?: ""}. Make sure both are on the same Wi-Fi.")
            }
            if (!delivered) buildRelay(pairing, qr.sessionId).apply { start() }.let { r ->
                withTimeoutOrNull(20_000) { while (r.state != LinkState.CONNECTED) delay(200) }
                check(r.send(ack)) { "Relay unreachable" }
            }
            // Wait for the Mac's encrypted AckEvent — proof it accepted this session.
            if (withTimeoutOrNull(30_000) { confirmed.await() } == null) {
                lan?.stop(); relay?.stop(); lan = null; relay = null; channel = null
                error("Your Mac didn't confirm. The code may have expired — tap New Code on the Mac and scan again.")
            }
            pairConfirmation = null
            store.pairing = pairing
            store.relayedCount = 0
            log(ActivityKind.LINK, "Paired with ${pairing.macName}")
            refreshState()
            startService()
            pairing.macName
        }
    }

    private fun relayConfigured(url: String) = url.isNotBlank() && !url.contains("yourdomain")

    private fun deviceName(): String {
        val model = Build.MODEL
        return if (model.startsWith(Build.MANUFACTURER, ignoreCase = true)) model else "${Build.MANUFACTURER} $model"
    }

    fun unpair() {
        stop()
        store.pairing = null
        ContextCompat.startForegroundService(app, Intent(app, RelayForegroundService::class.java).setAction(RelayForegroundService.STOP))
        _state.update { it.copy(activity = emptyList()) }
        refreshState()
    }

    // ------------------------------------------------------------------ lifecycle

    private val linkState = MutableStateFlow(LinkState.IDLE)

    private fun buildLan(p: Pairing): LanClient {
        lan?.stop()
        return LanClient(app, p.macDeviceId, p.lanHost) { host -> store.lanHost = host; refreshState() }.also { l ->
            l.onFrame = ::onFrame
            l.onState = { s -> linkState.value = s; if (s == LinkState.CONNECTED) channel?.resetEphemeral(); onLinkChanged() }
            lan = l
        }
    }

    private fun buildRelay(p: Pairing, pairingSession: String? = null): RelayClient {
        relay?.stop()
        return RelayClient(p.relayUrl, store.deviceId, store.privateKey, pairingSession, dev.phonepigeon.network.NetworkWatch(app)).also { r ->
            r.onFrame = ::onFrame
            r.onState = { s -> if (s == LinkState.CONNECTED) channel?.resetEphemeral(); onLinkChanged() }
            relay = r
        }
    }

    /** Starts the foreground service; if Android refuses a background start, relay in-process until we're killed. */
    fun startService() {
        runCatching { ContextCompat.startForegroundService(app, Intent(app, RelayForegroundService::class.java)) }
            .onFailure { Log.w("PhonePigeon", "FGS start refused (${it.javaClass.simpleName}); running in-process"); start() }
    }

    /** Called by RelayForegroundService. */
    @Synchronized
    fun start() {
        val p = store.pairing ?: return
        if (running) return
        running = true
        val keys = SessionKeys.derive(store.privateKey, p.macPublicKey, p.sessionId)
        if (channel == null) {
            channel = SecureChannel(keys, p.sessionId, store.deviceId, p.macDeviceId, store.outgoingSequence, store.incomingSequence)
        }
        mediaServer = MediaServer(app, keys.mediaToken, canRead = { store.allowFilesRead }, canWrite = { store.allowFilesWrite },
            canMirror = { store.allowScreen })

        if (lan == null) buildLan(p).start() else lan?.start()
        // The cloud link is only a fallback: it is opened when the Mac cannot be reached on the local network, and closed again
        // when it can, so two connections (and two sets of keep-alives) are never held at once.
        if (relayConfigured(p.relayUrl)) { buildRelay(p); manageRelay() }

        // Wi-Fi-only tablets have no telephony stack: each of these may fail without taking the app down.
        calls = runCatching { CallController(app) { ev -> onCallEvent(ev) }.also { it.start() } }.onFailure { Log.w("PhonePigeon", "calls unavailable: ${it.message}") }.getOrNull()
        runCatching { SmsRepository.observe(app) { m -> onLocalSms(m) } }.onFailure { Log.w("PhonePigeon", "SMS unavailable: ${it.message}") }
        runCatching { SimInventory.listen(app) { simCache = null; if (store.pairing != null) { send(PayloadBody(simInventory = SimInventorySync(cachedSims()))); refreshState() } } }

        heartbeat = scope.launch {
            while (isActive) {
                delay(300_000)
                // Nothing to tell a Mac that is not there; the status goes out on every reconnect anyway.
                if (lan?.state == LinkState.CONNECTED || relay?.state == LinkState.CONNECTED)
                    send(PayloadBody(deviceStatus = DeviceStatusReader.read(app)), queueIfOffline = false)
            }
        }
        if (store.relayedCount == 0) fullSync()
        onLinkChanged()
    }

    @Synchronized
    fun stop() {
        running = false
        heartbeat?.cancel()
        relayGate?.cancel(); relayGate = null
        lan?.stop(); relay?.stop(); calls?.stop(); mediaServer?.stop()
        mediaServer = null
        lan = null; relay = null; calls = null
        SmsRepository.stopObserving(app)
        channel?.let { store.outgoingSequence = it.outgoingSequence; store.incomingSequence = it.highestIncomingSequence }
        channel = null
        refreshState()
    }

    /** The phone's recent call history, for the Mac's Recents list. */
    private fun sendCallLog(limit: Int, queueIfOffline: Boolean = false) {
        if (!store.shareCalls) return
        val granted = app.has(android.Manifest.permission.READ_CALL_LOG)
        val rows = dev.phonepigeon.telephony.CallLogReader.recent(app, limit)
        send(PayloadBody(callLogSync = dev.phonepigeon.proto.CallLogSync(rows, granted)), queueIfOffline = queueIfOffline)
    }

    /** Re-send the call history (after the user grants the permission on the phone). */
    fun resendCallLog() { scope.launch(Dispatchers.IO) { sendCallLog(200) } }

    /** SIMs, contacts, last 500 messages and battery — sent once after pairing or on demand. */
    fun fullSync() = scope.launch(Dispatchers.IO) {
        send(PayloadBody(simInventory = SimInventorySync(SimInventory.read(app))))
        if (store.shareContacts) {
            val contacts = ContactsReader.read(app)
            contacts.chunked(100).forEachIndexed { i, chunk ->
                send(PayloadBody(contactSync = ContactSyncBatch(chunk, i == (contacts.size - 1) / 100)))
            }
        }
        if (store.shareSms) {
            val msgs = SmsRepository.initialSync(app)
            msgs.chunked(100).forEachIndexed { i, chunk ->
                send(PayloadBody(smsThreadSync = SmsThreadSync(chunk, i < (msgs.size - 1) / 100)))
            }
            log(ActivityKind.SYNC, "Synced ${msgs.size} messages")
        }
        sendCallLog(200)
        send(PayloadBody(deviceStatus = DeviceStatusReader.read(app)))
        store.relayedCount = maxOf(store.relayedCount, 1)
        refreshState()
    }

    // ------------------------------------------------------------------ inbound (Mac → phone)

    private fun onFrame(frame: WireFrame) {
        val env = frame.envelope ?: return
        val ch = channel ?: return
        val payload = runCatching { ch.open(env) }.onSuccess { if (it.body.rekey != null) Log.i("PhonePigeon", "rekey frame opened") }.getOrElse {
            Log.w("PhonePigeon", "Dropped envelope ${env.messageId}: ${it.message}"); return
        }
        store.incomingSequence = ch.highestIncomingSequence
        val body = payload.body
        if (body.ack != null) pairConfirmation?.complete(Unit)
        // The Mac restarted and lost our forward-secret keys: the channel already fell back to static keys, so say hello again.
        if (body.ack?.ackedMessageId == "resync") scope.launch(Dispatchers.IO) {
            send(PayloadBody(deviceStatus = DeviceStatusReader.read(app)), queueIfOffline = false)
        }
        body.rekey?.let { m ->
            val reply = ch.handleRekey(m)
            Log.i("PhonePigeon", "rekey request handled, reply=${reply != null}")
            reply?.let { send(it, queueIfOffline = false) }
        }
        body.sendSms?.let { cmd ->
            SmsRepository.send(app, cmd).onSuccess {
                log(ActivityKind.SMS_OUT, "Sent to ${cmd.recipientAddress} via SIM ${simLabel(cmd.subscriptionId)}")
            }.onFailure {
                send(PayloadBody(smsStatus = SmsStatusUpdate(cmd.clientRequestId, MessageStatus.FAILED, it.message ?: "Send failed")))
                log(ActivityKind.ERROR, "SMS failed: ${it.message}")
            }
        }
        body.placeCall?.let { cmd ->
            calls?.place(cmd)?.onSuccess { log(ActivityKind.CALL, "Calling ${cmd.phoneNumber} from Mac") }
                ?.onFailure { log(ActivityKind.ERROR, "Call failed: ${it.message}") }
        }
        body.callAction?.let { cmd ->
            calls?.act(cmd)?.onFailure { log(ActivityKind.ERROR, "${cmd.action.name.lowercase()}: ${it.message}") }
        }
        // Plane 2 metadata requests (spec v2 §6): answered over the E2EE control channel.
        body.notificationDismiss?.let { NotificationMirrorService.dismiss(it.key) }
        body.remoteInput?.let { handleRemoteInput(it) }
        body.screenReq?.let { req ->
            val sm = dev.phonepigeon.screen.ScreenMirror
            Log.i("PhonePigeon", "screen request ${req.action}, active=${sm.active}")
            when (req.action) {
                dev.phonepigeon.proto.ScreenAction.SCREEN_START -> when {
                    !store.allowScreen -> sm.report(dev.phonepigeon.proto.ScreenState.SCREEN_DENIED, message = "Screen mirroring is turned off on your phone (PhonePigeon › Mac access).")
                    sm.active -> sm.report(sm.lastStatus.state, sm.lastStatus.width, sm.lastStatus.height, sm.lastStatus.message)
                    else -> {
                        sm.report(dev.phonepigeon.proto.ScreenState.SCREEN_WAITING, message = "Waiting for you to approve on your phone…")
                        sm.requestFromMac(app, store.pairing?.macName ?: "Your Mac", req.maxDimension)
                        log(ActivityKind.LINK, "Mac asked to show your screen")
                    }
                }
                dev.phonepigeon.proto.ScreenAction.SCREEN_STOP -> { sm.cancelRequest(app); if (sm.active) sm.stop(app) else sm.report(dev.phonepigeon.proto.ScreenState.SCREEN_STOPPED) }
            }
        }
        body.listDirReq?.let { req ->
            scope.launch(Dispatchers.IO) {
                val res = if (store.allowFilesRead) MediaRepository.list(req)
                else dev.phonepigeon.proto.ListDirectoryResponse(req.requestId, req.path, emptyList(), "File access from the Mac is turned off on your phone.")
                send(PayloadBody(listDirRes = res))
            }
        }
        body.searchReq?.let { req ->
            scope.launch(Dispatchers.IO) {
                val res = if (store.allowFilesRead) MediaRepository.search(req)
                else dev.phonepigeon.proto.SearchFilesResponse(req.requestId, emptyList(), false, "File access from the Mac is turned off on your phone.")
                if (res.errorMessage.isNotEmpty() || res.entries.isNotEmpty() || res.requestId.isNotEmpty()) send(PayloadBody(searchRes = res))
            }
        }
        body.listGalleryReq?.let { req ->
            scope.launch(Dispatchers.IO) {
                val res = if (store.allowFilesRead) MediaRepository.gallery(app, req)
                else dev.phonepigeon.proto.ListMediaGalleryResponse(req.requestId, emptyList(), emptyList(), false)
                send(PayloadBody(listGalleryRes = res))
            }
        }
        body.fileOpReq?.let { req ->
            scope.launch(Dispatchers.IO) {
                val denied = when (req.op) {
                    dev.phonepigeon.proto.FileOpType.DELETE -> if (store.allowFilesDelete) null else "Deleting from the Mac is turned off on your phone (PhonePigeon › Mac access)."
                    dev.phonepigeon.proto.FileOpType.MKDIR, dev.phonepigeon.proto.FileOpType.RENAME ->
                        if (store.allowFilesWrite) null else "Changing files from the Mac is turned off on your phone (PhonePigeon › Mac access)."
                    else -> null
                }
                val res = if (denied != null) dev.phonepigeon.proto.FileOperationResponse(req.requestId, false, denied)
                else MediaRepository.apply(app, req)
                send(PayloadBody(fileOpRes = res))
                log(if (res.success) ActivityKind.SYNC else ActivityKind.ERROR, "${req.op.name.lowercase().replaceFirstChar { it.uppercase() }} ${req.sourcePath}")
            }
        }
    }

    private val inputTimes = ArrayDeque<Long>()

    /** Touch/keyboard from the Mac: only with the toggle on, the accessibility service enabled and a mirroring session live. */
    private fun handleRemoteInput(input: dev.phonepigeon.proto.RemoteInput) {
        val service = RemoteControlService.instance
        if (!store.allowRemoteControl || service == null || !dev.phonepigeon.screen.ScreenMirror.active) return
        val now = System.currentTimeMillis()
        synchronized(inputTimes) {
            while (inputTimes.isNotEmpty() && now - inputTimes.first() > 1000) inputTimes.removeFirst()
            if (inputTimes.size >= 30) return // at most 30 events per second
            inputTimes.addLast(now)
        }
        service.perform(input)
    }

    /** Sends a made-up notification so the whole path (phone → Mac) can be checked without waiting for a real one. */
    fun sendTestNotification() {
        sendFromService(PayloadBody(notification = dev.phonepigeon.proto.NotificationEvent(
            key = "phonepigeon-test-${System.currentTimeMillis()}", packageName = app.packageName, appName = "PhonePigeon",
            title = "Test notification", text = "If you can read this on your Mac, phone notifications are reaching it.",
            postedAtMs = System.currentTimeMillis())))
    }

    /** For the notification listener, which lives outside the engine's own threads. */
    fun sendFromService(body: PayloadBody) {
        if (store.pairing == null) return
        if (!running) startService()
        send(body, queueIfOffline = true)
    }

    // ------------------------------------------------------------------ outbound (phone → Mac)

    fun onLocalSms(m: SmsMessageEvent) {
        if (store.pairing == null || !store.shareSms) return
        if (!running) startService()
        send(PayloadBody(smsMessage = m))
        store.relayedCount += 1
        log(if (m.direction == MessageDirection.INCOMING) ActivityKind.SMS_IN else ActivityKind.SMS_OUT,
            (if (m.direction == MessageDirection.INCOMING) "From " else "To ") + m.address)
    }

    fun onSmsStatus(requestId: String, status: MessageStatus, error: String) {
        send(PayloadBody(smsStatus = SmsStatusUpdate(requestId, status, error)))
    }

    private fun onCallEvent(ev: CallStateEvent) {
        _state.update { it.copy(activeCall = ev.takeIf { e -> e.state != CallState.DISCONNECTED }) }
        if (!store.shareCalls) return
        send(PayloadBody(callState = ev))
        // The call log is written a moment after the line drops: send the newest rows then.
        if (ev.state == CallState.DISCONNECTED) scope.launch(Dispatchers.IO) { kotlinx.coroutines.delay(2500); sendCallLog(10) }
        if (ev.state == CallState.RINGING_INCOMING) log(ActivityKind.CALL, "Incoming call from ${ev.contactName.ifBlank { ev.remoteAddress }}")
    }

    private fun send(body: PayloadBody, queueIfOffline: Boolean = true) {
        val ch = channel
        val frame = ch?.let { runCatching { WireFrame(envelope = it.seal(body)) }.getOrNull() }
        val sent = frame != null && (lan?.send(frame) == true || relay?.send(frame) == true)
        if (!sent && queueIfOffline) synchronized(outbox) {
            outbox.addLast(body)
            while (outbox.size > 500) outbox.removeFirst()
        }
        persistOutgoingSequence(ch)
    }

    /**
     * The outgoing counter only has to be ahead of what the Mac has seen, and its stored value is floored at the clock, so it
     * is written at most every few seconds instead of after every message (each write rewrites the whole settings file).
     */
    private var lastSeqWrite = 0L
    private fun persistOutgoingSequence(ch: SecureChannel?) {
        ch ?: return
        val now = android.os.SystemClock.elapsedRealtime()
        if (now - lastSeqWrite < 5_000) return
        lastSeqWrite = now
        store.outgoingSequence = ch.outgoingSequence
    }

    // ---- cloud fallback gating
    private var relayGate: Job? = null

    @Synchronized
    private fun manageRelay() {
        val p = store.pairing ?: return
        val r = relay ?: return
        if (!running || !relayConfigured(p.relayUrl)) return
        if (lan?.state == LinkState.CONNECTED) {
            relayGate?.cancel(); relayGate = null
            if (r.state != LinkState.IDLE) r.stop()
        } else if (relayGate == null || relayGate?.isActive == false) {
            // Grace period: the local link usually comes up within seconds of launch or a Wi-Fi blip.
            relayGate = scope.launch {
                delay(15_000)
                if (lan?.state != LinkState.CONNECTED) r.start()
            }
        }
    }

    private var lastCallLogSync = -1_000_000L
    private var lanWasUp = false
    private var relayWasUp = false

    private fun onLinkChanged() {
        val lanUp = lan?.state == LinkState.CONNECTED
        val relayUp = relay?.state == LinkState.CONNECTED
        // Catch the Mac up once per link that comes up, not on every blip of either link.
        val newlyUp = (lanUp && !lanWasUp) || (relayUp && !relayWasUp && !lanUp)
        lanWasUp = lanUp; relayWasUp = relayUp
        manageRelay()
        if (newlyUp) {
            NotificationMirrorService.ensureBound(app)
            NotificationMirrorService.resync()
            val queued = synchronized(outbox) { outbox.toList().also { outbox.clear() } }
            scope.launch(Dispatchers.IO) {
                // Announce the LAN media server (cert pin + HKDF bearer) so the Mac can browse photos & files.
                mediaServer?.start()?.let { send(PayloadBody(mediaEndpoint = it), queueIfOffline = false) }
                send(PayloadBody(simInventory = SimInventorySync(SimInventory.read(app))), queueIfOffline = false)
                send(PayloadBody(deviceStatus = DeviceStatusReader.read(app)), queueIfOffline = false)
                // Calls made on the phone itself while the Mac was away. Reading the log is slow on some phones, so a Wi-Fi
                // blip that reconnects within two minutes does not read it again.
                val t = android.os.SystemClock.elapsedRealtime()
                if (t - lastCallLogSync > 120_000) { lastCallLogSync = t; sendCallLog(100) }
                queued.forEach { send(it) }
            }
        }
        refreshState()
    }

    // ------------------------------------------------------------------ UI helpers

    fun setShare(sms: Boolean? = null, calls: Boolean? = null, contacts: Boolean? = null,
                 filesRead: Boolean? = null, filesWrite: Boolean? = null, filesDelete: Boolean? = null, screen: Boolean? = null,
                 notifications: Boolean? = null, remoteControl: Boolean? = null) {
        sms?.let { store.shareSms = it }
        calls?.let { store.shareCalls = it }
        contacts?.let { store.shareContacts = it }
        filesRead?.let { store.allowFilesRead = it }
        filesWrite?.let { store.allowFilesWrite = it }
        filesDelete?.let { store.allowFilesDelete = it }
        notifications?.let { store.shareNotifications = it }
        remoteControl?.let { store.allowRemoteControl = it }
        screen?.let { store.allowScreen = it; if (!it && dev.phonepigeon.screen.ScreenMirror.active) dev.phonepigeon.screen.ScreenMirror.stop(app) }
        refreshState()
    }

    private fun simLabel(subId: Int) = _state.value.sims.firstOrNull { it.subscriptionId == subId }?.let { "${it.slotIndex + 1} · ${it.carrierName}" } ?: "$subId"

    private fun log(kind: ActivityKind, text: String) {
        _state.update { it.copy(activity = (listOf(Activity(kind, text)) + it.activity).take(40)) }
    }

    // Reading SIMs and hashing the fingerprints is not free and refreshState() runs on every link or counter change.
    @Volatile private var simCache: List<SimCard>? = null
    private fun cachedSims(): List<SimCard> = simCache ?: runCatching { SimInventory.read(app) }.getOrDefault(emptyList()).also { simCache = it }
    private val myFp by lazy { runCatching { Crypto.fingerprint(store.publicKey) }.getOrDefault("") }
    private var macFpKey: String? = null
    private var macFpValue = ""
    private fun macFp(p: Pairing): String {
        if (macFpKey != p.sessionId) { macFpValue = runCatching { Crypto.fingerprint(p.macPublicKey) }.getOrDefault(""); macFpKey = p.sessionId }
        return macFpValue
    }

    fun refreshState() {
        val p = store.pairing
        val connection = when {
            p == null -> Connection.OFFLINE
            lan?.state == LinkState.CONNECTED -> Connection.LAN
            relay?.state == LinkState.CONNECTED -> Connection.CLOUD
            running -> Connection.CONNECTING
            else -> Connection.OFFLINE
        }
        _state.update {
            it.copy(
                paired = p != null,
                macName = p?.macName.orEmpty(),
                connection = connection,
                lanHost = lan?.connectedHost ?: p?.lanHost,
                sims = cachedSims(),
                relayed = store.relayedCount,
                myFingerprint = myFp,
                macFingerprint = p?.let { macFp(it) }.orEmpty(),
                pairedAt = p?.pairedAt ?: 0,
                shareSms = store.shareSms,
                shareCalls = store.shareCalls,
                shareContacts = store.shareContacts,
                filesRead = store.allowFilesRead,
                filesWrite = store.allowFilesWrite,
                filesDelete = store.allowFilesDelete,
                screenMirror = store.allowScreen,
                shareNotifications = store.shareNotifications,
                remoteControl = store.allowRemoteControl,
            )
        }
    }
}
