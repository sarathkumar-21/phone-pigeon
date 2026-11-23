package dev.phonepigeon.telephony

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.telecom.Call
import android.telecom.CallAudioState
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telecom.VideoProfile
import android.telephony.PhoneStateListener
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import dev.phonepigeon.proto.AudioRoute
import dev.phonepigeon.proto.CallAction
import dev.phonepigeon.proto.CallActionCommand
import dev.phonepigeon.proto.CallState
import dev.phonepigeon.proto.CallStateEvent
import dev.phonepigeon.proto.PlaceCallCommand
import dev.phonepigeon.service.RelayInCallService
import java.util.ArrayDeque
import java.util.UUID

/**
 * Multi-SIM call control (spec §8.2.4).
 *
 * State is tracked per subscription with a PhoneStateListener (it is the only
 * non-role API that also reports the incoming number when READ_CALL_LOG is held).
 * When RelayInCallService is bound, actions go through the Telecom `Call` object
 * (answer, DTMF, mute, explicit audio routes incl. Bluetooth to the Mac). Otherwise
 * TelecomManager + AudioManager are used and DTMF is reported as unsupported.
 */
class CallController(private val context: Context, private val emit: (CallStateEvent) -> Unit) {
    private val telecom = context.getSystemService(TelecomManager::class.java)
    private val audio = context.getSystemService(AudioManager::class.java)
    private val listeners = mutableListOf<Pair<TelephonyManager, PhoneStateListener>>()

    private data class Live(val event: CallStateEvent, val lastState: Int, val reportOutcome: Boolean = false, val dialedAt: Long = 0)
    private val calls = mutableMapOf<Int, Live>()           // subId -> current call
    private var pendingOutgoing: PlaceCallCommand? = null
    private var pendingRouteToMac = false
    private var pendingDialedAt = 0L
    private val placeTimes = ArrayDeque<Long>()
    private val main = Handler(Looper.getMainLooper())

    init {
        RelayInCallService.onAudioChanged = { main.post { reemit() } }
    }

    private val ics get() = RelayInCallService.instance

    /** Current voice route, from Telecom when bound, otherwise inferred from AudioManager. */
    @Suppress("DEPRECATION")
    fun currentRoute(): AudioRoute {
        ics?.callAudioState?.let { s ->
            return when (s.route) {
                CallAudioState.ROUTE_BLUETOOTH -> AudioRoute.MAC_BLUETOOTH_HFP
                CallAudioState.ROUTE_SPEAKER -> AudioRoute.PHONE_SPEAKER
                CallAudioState.ROUTE_WIRED_HEADSET -> AudioRoute.WIRED_HEADSET
                else -> AudioRoute.PHONE_EARPIECE
            }
        }
        return when {
            audio.isBluetoothScoOn -> AudioRoute.MAC_BLUETOOTH_HFP
            audio.isSpeakerphoneOn -> AudioRoute.PHONE_SPEAKER
            else -> AudioRoute.PHONE_EARPIECE
        }
    }

    private fun muted() = ics?.callAudioState?.isMuted ?: audio.isMicrophoneMute

    private fun reemit() {
        val live = calls.values.firstOrNull() ?: return
        val ev = live.event.copy(audioRoute = currentRoute(), isMuted = muted())
        if (ev != live.event) { calls[ev.subscriptionId] = live.copy(event = ev); emit(ev) }
    }

    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    fun start() {
        stop()
        if (!context.has(Manifest.permission.READ_PHONE_STATE)) return
        val sm = context.getSystemService(SubscriptionManager::class.java)
        val tm = context.getSystemService(TelephonyManager::class.java)
        val subs = sm?.activeSubscriptionInfoList.orEmpty().map { it.subscriptionId }.ifEmpty { listOf(SubscriptionManager.getDefaultVoiceSubscriptionId()) }
        for (subId in subs) {
            val perSub = tm.createForSubscriptionId(subId)
            val l = object : PhoneStateListener() {
                override fun onCallStateChanged(state: Int, phoneNumber: String?) = handle(subId, state, phoneNumber.orEmpty())
            }
            perSub.listen(l, PhoneStateListener.LISTEN_CALL_STATE)
            listeners += perSub to l
        }
    }

    @Suppress("DEPRECATION")
    fun stop() {
        listeners.forEach { (tm, l) -> tm.listen(l, PhoneStateListener.LISTEN_NONE) }
        listeners.clear()
    }

    private fun handle(subId: Int, state: Int, rawNumber: String) {
        val number = if (rawNumber.isNotBlank()) Phone.normalize(context, rawNumber) else ""
        val prev = calls[subId]
        val now = System.currentTimeMillis()
        when (state) {
            TelephonyManager.CALL_STATE_RINGING -> {
                if (prev != null) return
                val ev = CallStateEvent(UUID.randomUUID().toString(), subId, number, Phone.contactName(context, number).orEmpty(),
                    CallState.RINGING_INCOMING, currentRoute(), 0, false)
                calls[subId] = Live(ev, state)
                emit(ev)
                sendPhotoLater(ev.callId, number) // decoding a photo takes a moment: don't hold the phone-state callback
            }
            TelephonyManager.CALL_STATE_OFFHOOK -> {
                val outgoingCmd = pendingOutgoing
                val reportOutcome = prev?.reportOutcome ?: (outgoingCmd?.reportOutcome == true)
                val dialedAt = prev?.dialedAt?.takeIf { it > 0 } ?: pendingDialedAt.takeIf { it > 0 } ?: now
                val base = prev?.event ?: outgoingCmd?.let { cmd ->
                    CallStateEvent(cmd.requestId, subId, cmd.phoneNumber, Phone.contactName(context, cmd.phoneNumber).orEmpty(),
                        CallState.DIALING_OUTGOING, currentRoute(), 0, false)
                } ?: CallStateEvent(UUID.randomUUID().toString(), subId, number, Phone.contactName(context, number).orEmpty(),
                    CallState.DIALING_OUTGOING, currentRoute(), 0, false)
                pendingOutgoing = null
                if (prev?.lastState == TelephonyManager.CALL_STATE_OFFHOOK) return
                val wantMac = pendingRouteToMac
                pendingRouteToMac = false
                val ev = base.copy(state = CallState.ACTIVE, startedAtMs = now, isMuted = muted(), audioRoute = currentRoute())
                calls[subId] = Live(ev, state, reportOutcome, dialedAt); emit(ev)
                // Spec §5.2.5: keep voice on the Mac for calls dialled from the Mac.
                if (wantMac) main.postDelayed({ setRoute(AudioRoute.MAC_BLUETOOTH_HFP) }, 600)
            }
            TelephonyManager.CALL_STATE_IDLE -> {
                prev?.let { finish(subId, it) }
                // Dual-SIM phones sometimes report the hang-up on the other SIM's listener only, which left a missed call
                // ringing on the Mac. When the phone as a whole is idle, nothing can still be live.
                if (phoneIsIdle()) calls.toMap().forEach { (id, live) -> finish(id, live) }
            }
        }
    }

    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    private fun phoneIsIdle(): Boolean = runCatching {
        context.getSystemService(TelephonyManager::class.java).callState == TelephonyManager.CALL_STATE_IDLE
    }.getOrDefault(false)

    private fun finish(subId: Int, live: Live) {
        if (calls.remove(subId) == null) return
        if (audio.isMicrophoneMute) audio.isMicrophoneMute = false
        val ended = live.event.copy(state = CallState.DISCONNECTED)
        if (live.reportOutcome && context.has(Manifest.permission.READ_CALL_LOG)) {
            // The call log is written a moment after the line drops: look for a second or two, then report.
            Thread {
                var seconds: Int? = null
                repeat(8) {
                    if (seconds == null) { seconds = CallOutcome.durationSeconds(context, ended.remoteAddress, live.dialedAt); if (seconds == null) Thread.sleep(300) }
                }
                main.post { emit(ended.copy(answered = seconds?.let { it > 0 }, durationS = seconds)) }
            }.start()
        } else emit(ended)
    }

    // -------------------------------------------------------------- commands from Mac

    /**
     * The caller's contact photo goes to the Mac once, as an update of the call's current state, from a background thread.
     * Skipped if the call is already over by the time it is ready (a late event must not bring a finished call back).
     */
    private fun sendPhotoLater(callId: String, number: String) {
        Thread {
            val photo = Phone.contactPhoto(context, number) ?: return@Thread
            fun attempt(n: Int) {
                val live = calls.values.firstOrNull { it.event.callId == callId }
                if (live != null) emit(live.event.copy(photoJpeg = photo))
                else if (n < 8 && pendingOutgoing?.requestId == callId) main.postDelayed({ attempt(n + 1) }, 250)
            }
            main.post { attempt(0) }
        }.start()
    }

    /** A Mac (or a runaway auto-redial loop) may start at most 30 calls per 10 minutes. */
    @Synchronized
    private fun allowPlace(now: Long = System.currentTimeMillis()): Boolean {
        while (placeTimes.isNotEmpty() && now - placeTimes.first() > 600_000) placeTimes.removeFirst()
        if (placeTimes.size >= 30) return false
        placeTimes.addLast(now)
        return true
    }

    @SuppressLint("MissingPermission")
    fun place(cmd: PlaceCallCommand): Result<Unit> = runCatching {
        check(context.has(Manifest.permission.CALL_PHONE)) { "CALL_PHONE permission not granted" }
        check(Phone.isPlainNumber(cmd.phoneNumber)) { "Refused: that isn't a plain phone number" }
        check(allowPlace()) { "Too many calls started from the Mac in the last 10 minutes" }
        pendingOutgoing = cmd
        pendingRouteToMac = cmd.routeAudioToMac
        pendingDialedAt = System.currentTimeMillis()
        emit(CallStateEvent(cmd.requestId, cmd.subscriptionId, cmd.phoneNumber, Phone.contactName(context, cmd.phoneNumber).orEmpty(),
            CallState.DIALING_OUTGOING, if (cmd.routeAudioToMac) AudioRoute.MAC_BLUETOOTH_HFP else AudioRoute.PHONE_EARPIECE, 0, false))
        sendPhotoLater(cmd.requestId, cmd.phoneNumber)
        val extras = Bundle()
        accountFor(cmd.subscriptionId)?.let { extras.putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, it) }
        telecom.placeCall(Uri.fromParts("tel", cmd.phoneNumber, null), extras)
    }

    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    fun act(cmd: CallActionCommand): Result<Unit> = runCatching {
        val live = calls.values.firstOrNull { it.event.callId == cmd.callId } ?: calls.values.firstOrNull()
        val call = ics?.activeCall
        when (cmd.action) {
            CallAction.ANSWER -> if (call != null) call.answer(VideoProfile.STATE_AUDIO_ONLY) else {
                check(context.has(Manifest.permission.ANSWER_PHONE_CALLS)); telecom.acceptRingingCall()
            }
            CallAction.REJECT -> if (call?.state == Call.STATE_RINGING) call.reject(false, null) else endCall(live)
            CallAction.END_CALL -> if (call != null) call.disconnect() else endCall(live)
            CallAction.TOGGLE_MUTE -> {
                val now = !muted()
                ics?.setMuted(now) ?: run { audio.isMicrophoneMute = now }
                main.postDelayed({ reemit() }, 150)
            }
            CallAction.SEND_DTMF -> {
                val digit = cmd.dtmfDigit.firstOrNull() ?: error("No digit")
                val c = call ?: error("DTMF needs PhonePigeon's call service — enable it under Phone › Calls on the phone")
                c.playDtmfTone(digit)
                main.postDelayed({ c.stopDtmfTone() }, 180)
            }
            CallAction.SWITCH_AUDIO_ROUTE -> setRoute(cmd.targetAudioRoute)
            CallAction.CALL_ACTION_UNSPECIFIED -> Unit
        }
    }

    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    private fun endCall(live: Live?) {
        check(context.has(Manifest.permission.ANSWER_PHONE_CALLS))
        if (!telecom.endCall() && live != null) emit(live.event.copy(state = CallState.DISCONNECTED))
    }

    /** Spec §5.2.5 / §5.3.7: explicit routing — Mac (Bluetooth HFP), phone speaker or earpiece. */
    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    fun setRoute(target: AudioRoute) {
        val svc = ics
        if (svc != null) {
            when (target) {
                AudioRoute.MAC_BLUETOOTH_HFP -> {
                    val bt: BluetoothDevice? = if (Build.VERSION.SDK_INT >= 28) svc.callAudioState?.supportedBluetoothDevices?.firstOrNull() else null
                    if (bt != null && Build.VERSION.SDK_INT >= 28) svc.requestBluetoothAudio(bt) else svc.setAudioRoute(CallAudioState.ROUTE_BLUETOOTH)
                }
                AudioRoute.PHONE_SPEAKER -> svc.setAudioRoute(CallAudioState.ROUTE_SPEAKER)
                AudioRoute.WIRED_HEADSET -> svc.setAudioRoute(CallAudioState.ROUTE_WIRED_HEADSET)
                else -> svc.setAudioRoute(CallAudioState.ROUTE_EARPIECE)
            }
        } else {
            // Fallback without the call service: best-effort via AudioManager.
            audio.isSpeakerphoneOn = target == AudioRoute.PHONE_SPEAKER
            if (target == AudioRoute.MAC_BLUETOOTH_HFP && Build.VERSION.SDK_INT >= 31) {
                audio.availableCommunicationDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
                    ?.let { audio.setCommunicationDevice(it) }
            } else if (Build.VERSION.SDK_INT >= 31 && target != AudioRoute.MAC_BLUETOOTH_HFP) {
                audio.clearCommunicationDevice()
            }
        }
        main.postDelayed({ reemit() }, 300)
    }

    /** Maps a subscription id to its PhoneAccountHandle (spec §8.2.4). */
    @SuppressLint("MissingPermission")
    private fun accountFor(subId: Int): PhoneAccountHandle? {
        val accounts = runCatching { telecom.callCapablePhoneAccounts }.getOrNull().orEmpty()
        if (Build.VERSION.SDK_INT >= 30) {
            val tm = context.getSystemService(TelephonyManager::class.java)
            accounts.firstOrNull { runCatching { tm.getSubscriptionId(it) }.getOrNull() == subId }?.let { return it }
        }
        accounts.firstOrNull { it.id == subId.toString() || it.id.contains(subId.toString()) }?.let { return it }
        val slot = SubscriptionManager.getSlotIndex(subId)
        return accounts.getOrNull(slot)
    }
}
