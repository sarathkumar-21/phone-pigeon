package dev.phonepigeon.data

import android.content.Context
import android.util.Base64
import androidx.core.content.edit
import dev.phonepigeon.crypto.Crypto
import dev.phonepigeon.crypto.KeystoreBox
import java.util.UUID

data class Pairing(
    val sessionId: String,
    val macDeviceId: String,
    val macPublicKey: ByteArray,
    val relayUrl: String,
    val lanHost: String?,
    val pairedAt: Long,
    val macName: String,
)

/**
 * Persists identity + pairing. The X25519 private key is wrapped by an
 * Android Keystore AES-GCM key (spec §5.1: "Android Keystore / EncryptedSharedPreferences").
 */
class PairingStore(context: Context) {
    private val prefs = context.getSharedPreferences("phonepigeon", Context.MODE_PRIVATE)

    val deviceId: String
        get() = prefs.getString("device_id", null) ?: UUID.randomUUID().toString().also { prefs.edit { putString("device_id", it) } }

    /** Long-term Curve25519 identity for this phone. */
    val privateKey: ByteArray
        @Synchronized get() {
            prefs.getString("identity", null)?.let { stored ->
                runCatching { return KeystoreBox.unwrap(Base64.decode(stored, Base64.NO_WRAP)) }
                // The Keystore key is gone or unusable (restore, lock-screen reset…). A replacement identity cannot
                // be trusted by the paired Mac, so drop the pairing instead of silently continuing with a new key.
                prefs.edit {
                    listOf("p_session", "p_mac_id", "p_mac_key", "p_relay", "p_lan", "p_at", "p_mac_name", "seq_out", "seq_in", "relayed").forEach(::remove)
                    putBoolean("identity_lost", true)
                }
            }
            val key = Crypto.generatePrivateKey()
            prefs.edit { putString("identity", Base64.encodeToString(KeystoreBox.wrap(key), Base64.NO_WRAP)) }
            return key
        }

    /** True once if the identity key had to be regenerated and the old pairing was removed. */
    fun takeIdentityLost(): Boolean = prefs.getBoolean("identity_lost", false).also { if (it) prefs.edit { remove("identity_lost") } }

    val publicKey: ByteArray get() = Crypto.publicKey(privateKey)

    var pairing: Pairing?
        get() {
            val session = prefs.getString("p_session", null) ?: return null
            return Pairing(
                sessionId = session,
                macDeviceId = prefs.getString("p_mac_id", "")!!,
                macPublicKey = Base64.decode(prefs.getString("p_mac_key", ""), Base64.NO_WRAP),
                relayUrl = prefs.getString("p_relay", "")!!,
                lanHost = prefs.getString("p_lan", null),
                pairedAt = prefs.getLong("p_at", 0),
                macName = prefs.getString("p_mac_name", "Mac") ?: "Mac",
            )
        }
        set(value) = prefs.edit {
            if (value == null) {
                listOf("p_session", "p_mac_id", "p_mac_key", "p_relay", "p_lan", "p_at", "p_mac_name", "seq_out", "seq_in", "relayed").forEach(::remove)
            } else {
                putString("p_session", value.sessionId)
                putString("p_mac_id", value.macDeviceId)
                putString("p_mac_key", Base64.encodeToString(value.macPublicKey, Base64.NO_WRAP))
                putString("p_relay", value.relayUrl)
                putString("p_lan", value.lanHost)
                putLong("p_at", value.pairedAt)
                putString("p_mac_name", value.macName)
            }
        }

    var lanHost: String?
        get() = prefs.getString("p_lan", null)
        set(v) = prefs.edit { putString("p_lan", v) }

    var incomingSequence: Long
        get() = prefs.getLong("seq_in", 0)
        set(v) = prefs.edit { putLong("seq_in", v) }

    /** Time-based floor keeps outgoing sequence numbers monotonic across restarts. */
    var outgoingSequence: Long
        get() = maxOf(prefs.getLong("seq_out", 0), System.currentTimeMillis())
        set(v) = prefs.edit { putLong("seq_out", v) }

    var shareSms: Boolean
        get() = prefs.getBoolean("share_sms", true)
        set(v) = prefs.edit { putBoolean("share_sms", v) }
    var shareCalls: Boolean
        get() = prefs.getBoolean("share_calls", true)
        set(v) = prefs.edit { putBoolean("share_calls", v) }
    var shareContacts: Boolean
        get() = prefs.getBoolean("share_contacts", true)
        set(v) = prefs.edit { putBoolean("share_contacts", v) }

    /** What a paired Mac may do with phone storage. Delete is off by default (least privilege). */
    var allowFilesRead: Boolean
        get() = prefs.getBoolean("files_read", true)
        set(v) = prefs.edit { putBoolean("files_read", v) }
    var allowFilesWrite: Boolean
        get() = prefs.getBoolean("files_write", true)
        set(v) = prefs.edit { putBoolean("files_write", v) }
    var allowFilesDelete: Boolean
        get() = prefs.getBoolean("files_delete", false)
        set(v) = prefs.edit { putBoolean("files_delete", v) }

    /** Whether the Mac may ask to mirror the screen (every session still needs on-phone approval). */
    var allowScreen: Boolean
        get() = prefs.getBoolean("screen_mirror", true)
        set(v) = prefs.edit { putBoolean("screen_mirror", v) }

    /** Mirror the phone's notifications to the Mac (also needs Notification access in Android settings). */
    var shareNotifications: Boolean
        get() = prefs.getBoolean("share_notifications", true)
        set(v) = prefs.edit { putBoolean("share_notifications", v) }

    /** Let the Mac tap, swipe and type while screen mirroring runs. Off by default (needs the accessibility service). */
    var allowRemoteControl: Boolean
        get() = prefs.getBoolean("remote_control", false)
        set(v) = prefs.edit { putBoolean("remote_control", v) }

    var relayedCount: Int
        get() = prefs.getInt("relayed", 0)
        set(v) = prefs.edit { putInt("relayed", v) }

    fun rotateIdentity() {
        prefs.edit { remove("identity") }
        KeystoreBox.delete()
    }
}
