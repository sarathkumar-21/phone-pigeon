package dev.phonepigeon.service

import android.telecom.Call
import android.telecom.CallAudioState
import android.telecom.InCallService

/**
 * Non-UI companion InCallService (spec v2 §10.2). When Telecom binds it (companion
 * association or dialer role), PhonePigeon gets exact call states, DTMF, mute and explicit
 * audio routing — including `requestBluetoothAudio(macDevice)` to keep voice on the Mac.
 * Without it, CallController falls back to TelecomManager + AudioManager.
 */
class RelayInCallService : InCallService() {
    companion object {
        @Volatile var instance: RelayInCallService? = null
            private set
        /** Notified on audio-route changes so the Mac's call bar stays in sync. */
        @Volatile var onAudioChanged: ((CallAudioState) -> Unit)? = null
        @Volatile var onCallsChanged: (() -> Unit)? = null
    }

    val activeCall: Call? get() = calls.firstOrNull { it.state != Call.STATE_DISCONNECTED }

    override fun onCreate() { super.onCreate(); instance = this }
    override fun onDestroy() { instance = null; super.onDestroy() }

    override fun onCallAdded(call: Call) { onCallsChanged?.invoke() }
    override fun onCallRemoved(call: Call) { onCallsChanged?.invoke() }
    override fun onCallAudioStateChanged(audioState: CallAudioState) { onAudioChanged?.invoke(audioState) }
}
