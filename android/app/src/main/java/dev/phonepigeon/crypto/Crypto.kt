package dev.phonepigeon.crypto

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.google.crypto.tink.subtle.X25519
import dev.phonepigeon.proto.DevicePayload
import dev.phonepigeon.proto.EncryptedEnvelope
import dev.phonepigeon.proto.PairAckBody
import dev.phonepigeon.proto.PayloadBody
import dev.phonepigeon.proto.RekeyMessage
import dev.phonepigeon.proto.WireCodec
import java.nio.ByteBuffer
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

object Crypto {
    private val random = SecureRandom()

    fun randomBytes(n: Int) = ByteArray(n).also(random::nextBytes)

    fun sha256Hex(s: String): String =
        MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }

    /** "7F3A · 91C2 · 0B4E · D8A1 · …" (128 bits) — same format as the Mac for side-by-side comparison. */
    fun fingerprint(key: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(key).take(16)
            .joinToString("") { "%02X".format(it) }.chunked(4).joinToString(" · ")

    /** What the Mac advertises over Bonjour instead of its raw device id (which would be a stable LAN-wide tracker). */
    fun mdnsTag(macDeviceId: String): String =
        MessageDigest.getInstance("SHA-256").digest("phonepigeon-mdns-v1$macDeviceId".toByteArray())
            .take(8).joinToString("") { "%02x".format(it) }

    /** Proves the phone saw the QR (whose secret never reaches the relay). Mirrors the Mac's check. */
    fun pairProof(secret: ByteArray, sessionId: String, phonePub: ByteArray, macPub: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(secret, "HmacSHA256"))
        mac.update("phonepigeon-pair-v1".toByteArray())
        mac.update(sessionId.toByteArray())
        mac.update(phonePub)
        mac.update(macPub)
        return mac.doFinal()
    }

    // ------------------------------------------------------------ X25519

    fun generatePrivateKey(): ByteArray = X25519.generatePrivateKey()
    fun publicKey(privateKey: ByteArray): ByteArray = X25519.publicFromPrivate(privateKey)
    fun sharedSecret(privateKey: ByteArray, peerPublic: ByteArray): ByteArray = X25519.computeSharedSecret(privateKey, peerPublic)

    // ------------------------------------------------------------ HKDF-SHA256 (RFC 5869)

    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int = 32): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(if (salt.isEmpty()) ByteArray(32) else salt, "HmacSHA256"))
        val prk = mac.doFinal(ikm)
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val out = ByteArray(length)
        var t = ByteArray(0)
        var pos = 0
        var counter = 1
        while (pos < length) {
            mac.update(t); mac.update(info); mac.update(counter.toByte())
            t = mac.doFinal()
            val n = minOf(t.size, length - pos)
            System.arraycopy(t, 0, out, pos, n)
            pos += n; counter++
        }
        return out
    }

    // ------------------------------------------------------------ ChaCha20-Poly1305 (ciphertext ‖ 16-byte tag)

    fun seal(key: ByteArray, nonce: ByteArray, plaintext: ByteArray, aad: ByteArray? = null): ByteArray {
        val c = Cipher.getInstance("ChaCha20/Poly1305/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "ChaCha20"), IvParameterSpec(nonce))
        if (aad != null) c.updateAAD(aad)
        return c.doFinal(plaintext)
    }

    fun open(key: ByteArray, nonce: ByteArray, ciphertextAndTag: ByteArray, aad: ByteArray? = null): ByteArray {
        val c = Cipher.getInstance("ChaCha20/Poly1305/NoPadding")
        c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "ChaCha20"), IvParameterSpec(nonce))
        if (aad != null) c.updateAAD(aad)
        return c.doFinal(ciphertextAndTag)
    }
}

/** Directional keys (spec §5.1 step 3). Android sends with K_and_to_mac. */
class SessionKeys(val sendKey: ByteArray, val receiveKey: ByteArray, val mediaToken: ByteArray, val staticShared: ByteArray) {
    companion object {
        fun derive(privateKey: ByteArray, macPublicKey: ByteArray, sessionId: String): SessionKeys {
            val shared = Crypto.sharedSecret(privateKey, macPublicKey)
            val salt = sessionId.toByteArray()
            return SessionKeys(
                sendKey = Crypto.hkdf(shared, salt, "and->mac".toByteArray()),
                receiveKey = Crypto.hkdf(shared, salt, "mac->and".toByteArray()),
                // K_media_token (spec v2 §7.1): authorises requests to the embedded media server.
                mediaToken = Crypto.hkdf(shared, salt, "media-http-auth".toByteArray()),
                staticShared = shared,
            )
        }
    }
}

/** Keys for one re-key epoch: static secret ‖ fresh ephemeral X25519 secret (forward secrecy for live traffic). */
class EphemeralKeys(val send: ByteArray, val receive: ByteArray, val epoch: String) {
    companion object {
        fun deriveAndroid(staticShared: ByteArray, ephemeralShared: ByteArray, sessionId: String, epoch: String): EphemeralKeys {
            val ikm = staticShared + ephemeralShared
            val salt = "$sessionId|$epoch".toByteArray()
            return EphemeralKeys(
                send = Crypto.hkdf(ikm, salt, "and->mac/eph".toByteArray()),
                receive = Crypto.hkdf(ikm, salt, "mac->and/eph".toByteArray()),
                epoch = epoch,
            )
        }
    }
}

class SecureChannelException(message: String) : Exception(message)

/**
 * ChaCha20-Poly1305 channel. Nonce = 8-byte random prefix ‖ 4-byte big-endian counter (a prefix collision
 * across restarts is negligible). Routing header is bound as AAD so the relay cannot re-route
 * ciphertext. Sequence numbers give replay protection (spec §5.2).
 *
 * Forward secrecy (best effort): the Mac starts an ephemeral X25519 exchange (`rekey` payloads under the static
 * keys). After it, live traffic uses keys that mix in the discarded ephemeral secret. Static keys always remain
 * valid for *receiving*, so restarts and relay-queued frames can never become undecryptable.
 */
class SecureChannel(
    private val keys: SessionKeys,
    private val sessionId: String,
    val localDeviceId: String,
    val peerDeviceId: String,
    var outgoingSequence: Long,
    var highestIncomingSequence: Long,
) {
    private val noncePrefix = Crypto.randomBytes(8)
    private var nonceCounter = 0
    private var eph: EphemeralKeys? = null
    private var pending: EphemeralKeys? = null
    private var lastPeerFrame = 0L

    private fun nextNonce(): ByteArray {
        check(nonceCounter < Int.MAX_VALUE - 1) { "nonce space exhausted" }
        nonceCounter += 1
        return ByteBuffer.allocate(12).put(noncePrefix).putInt(nonceCounter).array()
    }

    @Synchronized
    fun seal(body: PayloadBody): EncryptedEnvelope {
        outgoingSequence += 1
        val payload = DevicePayload(outgoingSequence, System.currentTimeMillis(), body)
        val plaintext = WireCodec.json.encodeToString(DevicePayload.serializer(), payload).toByteArray()
        val nonce = nextNonce()
        val aad = "$localDeviceId→$peerDeviceId".toByteArray()
        val e = eph
        val key = if (e != null && body.rekey == null && System.currentTimeMillis() - lastPeerFrame < EPHEMERAL_FRESH_MS) e.send else keys.sendKey
        return EncryptedEnvelope(
            messageId = UUID.randomUUID().toString(),
            senderDeviceId = localDeviceId,
            targetDeviceId = peerDeviceId,
            nonce = nonce,
            ciphertext = Crypto.seal(key, nonce, plaintext, aad),
            requiresWakeup = body.requiresWakeup,
        )
    }

    @Synchronized
    fun open(env: EncryptedEnvelope): DevicePayload {
        if (env.ciphertext.size < 16) throw SecureChannelException("Malformed ciphertext")
        val aad = "${env.senderDeviceId}→${env.targetDeviceId}".toByteArray()
        var used = 2 // 0 ephemeral, 1 pending, 2 static
        val plain: ByteArray = eph?.let { runCatching { Crypto.open(it.receive, env.nonce, env.ciphertext, aad) }.getOrNull() }?.also { used = 0 }
            ?: pending?.let { runCatching { Crypto.open(it.receive, env.nonce, env.ciphertext, aad) }.getOrNull() }?.also { used = 1 }
            ?: Crypto.open(keys.receiveKey, env.nonce, env.ciphertext, aad)
        val payload = WireCodec.json.decodeFromString(DevicePayload.serializer(), plain.decodeToString())
        if (payload.sequenceNumber <= highestIncomingSequence) {
            throw SecureChannelException("Replayed packet (seq ${payload.sequenceNumber})")
        }
        if (payload.body.isLive && kotlin.math.abs(System.currentTimeMillis() - payload.clientTimestampMs) > 5 * 60_000) {
            throw SecureChannelException("Clock skew > 5 minutes on live command")
        }
        highestIncomingSequence = payload.sequenceNumber
        lastPeerFrame = System.currentTimeMillis()
        when {
            used == 1 -> { eph = pending; pending = null }
            // The Mac is sending under static keys (it restarted or was offline): stop assuming it holds ours.
            used == 2 && payload.body.rekey == null && (eph != null || pending != null) -> { eph = null; pending = null }
        }
        return payload
    }

    /** Forget the forward-secret keys (a new connection: the Mac may have restarted and lost them). Static keys always work. */
    @Synchronized
    fun resetEphemeral() { eph = null; pending = null }

    /** Answers the Mac's ephemeral exchange; the new keys are promoted when the first message under them arrives. */
    @Synchronized
    fun handleRekey(m: RekeyMessage): PayloadBody? {
        if (m.reply || m.ephPub.size != 32) return null
        val priv = Crypto.generatePrivateKey()
        val shared = runCatching { Crypto.sharedSecret(priv, m.ephPub) }.getOrNull() ?: return null
        pending = EphemeralKeys.deriveAndroid(keys.staticShared, shared, sessionId, m.epochId)
        return PayloadBody(rekey = RekeyMessage(m.epochId, Crypto.publicKey(priv), reply = true))
    }

    companion object {
        private const val EPHEMERAL_FRESH_MS = 120_000L

        /** PairAck is sealed with K_and_to_mac under a random nonce, no AAD. */
        fun sealPairAck(body: PairAckBody, keys: SessionKeys): Pair<ByteArray, ByteArray> {
            val nonce = Crypto.randomBytes(12)
            val plain = WireCodec.json.encodeToString(PairAckBody.serializer(), body).toByteArray()
            return nonce to Crypto.seal(keys.sendKey, nonce, plain)
        }
    }
}

/** Wraps secrets with a non-exportable AES-GCM key in the Android Keystore. */
object KeystoreBox {
    private const val ALIAS = "phonepigeon-wrap-key"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    fun wrap(secret: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        return c.iv + c.doFinal(secret)
    }

    fun unwrap(blob: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, blob.copyOfRange(0, 12)))
        return c.doFinal(blob.copyOfRange(12, blob.size))
    }

    fun delete() {
        runCatching { KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(ALIAS) }
    }
}
