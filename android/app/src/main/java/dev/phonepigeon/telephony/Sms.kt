package dev.phonepigeon.telephony

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Telephony
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import dev.phonepigeon.crypto.Crypto
import dev.phonepigeon.proto.MessageDirection
import dev.phonepigeon.proto.MessageStatus
import dev.phonepigeon.proto.SendSmsCommand
import dev.phonepigeon.proto.SmsMessageEvent
import dev.phonepigeon.service.RelayEngine
import java.util.Collections
import java.util.UUID

/**
 * SMS engine (spec §8.2.2–3): initial sync, real-time capture via BroadcastReceiver
 * AND ContentObserver, OEM-duplicate suppression, and per-SIM multipart sending.
 */
object SmsRepository {
    private val seen = Collections.synchronizedSet(LinkedHashSet<String>())
    private var lastProviderId = -1L
    private var observer: ContentObserver? = null

    private fun prefs(context: Context) = context.getSharedPreferences("phonepigeon", Context.MODE_PRIVATE)
    private fun saveCursor(context: Context) = prefs(context).edit().putLong("last_sms_id", lastProviderId).apply()

    /** Spec dedup key: (normalizeE164(address), body.trim(), timestampMs / 5000). */
    private fun keys(address: String, body: String, ts: Long): List<String> {
        val base = "${address}|${body.trim()}|"
        val bucket = ts / 5000
        return listOf(base + bucket, base + (bucket - 1), base + (bucket + 1))
    }

    /** Returns true if this message has not been seen before (and records it). */
    fun firstSighting(address: String, body: String, ts: Long): Boolean {
        val k = keys(address, body, ts)
        synchronized(seen) {
            if (k.any { it in seen }) return false
            seen += k[0]
            if (seen.size > 2000) seen.iterator().run { repeat(500) { next(); remove() } }
        }
        return true
    }

    private val threadIds = HashMap<String, String>()

    @Synchronized
    fun threadId(address: String): String = threadIds.getOrPut(address) { Crypto.sha256Hex(address) }

    // ------------------------------------------------------------------ reading

    @SuppressLint("Range")
    fun recent(context: Context, limit: Int = 500, afterId: Long = -1): List<Pair<Long, SmsMessageEvent>> {
        if (!context.has(Manifest.permission.READ_SMS)) return emptyList()
        val out = ArrayList<Pair<Long, SmsMessageEvent>>()
        val selection = if (afterId >= 0) "${Telephony.Sms._ID} > ?" else null
        val args = if (afterId >= 0) arrayOf(afterId.toString()) else null
        val projection = arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE,
            Telephony.Sms.TYPE, Telephony.Sms.READ, Telephony.Sms.STATUS, Telephony.Sms.SUBSCRIPTION_ID)
        context.contentResolver.query(Telephony.Sms.CONTENT_URI, projection, selection, args, "${Telephony.Sms.DATE} DESC")?.use { c ->
            while (c.moveToNext() && out.size < limit) {
                val id = c.getLong(0)
                val rawAddress = c.getString(1) ?: continue
                val body = c.getString(2) ?: continue
                val type = c.getInt(4)
                val direction = if (type == Telephony.Sms.MESSAGE_TYPE_INBOX) MessageDirection.INCOMING else MessageDirection.OUTGOING
                val status = when {
                    type == Telephony.Sms.MESSAGE_TYPE_FAILED -> MessageStatus.FAILED
                    type == Telephony.Sms.MESSAGE_TYPE_OUTBOX || type == Telephony.Sms.MESSAGE_TYPE_QUEUED -> MessageStatus.PENDING
                    direction == MessageDirection.OUTGOING && c.getInt(6) == Telephony.Sms.STATUS_COMPLETE -> MessageStatus.DELIVERED
                    direction == MessageDirection.OUTGOING -> MessageStatus.SENT
                    else -> MessageStatus.DELIVERED
                }
                val address = Phone.normalize(context, rawAddress)
                out += id to SmsMessageEvent(
                    localId = "sms-$id",
                    threadId = threadId(address),
                    subscriptionId = c.getInt(7),
                    address = address,
                    body = body,
                    direction = direction,
                    status = status,
                    timestampMs = c.getLong(3),
                    isRead = c.getInt(5) == 1,
                )
            }
        }
        return out
    }

    /** Initial sync — newest 500 messages, oldest first. Seeds the dedup cache. */
    fun initialSync(context: Context): List<SmsMessageEvent> {
        val rows = recent(context)
        lastProviderId = maxOf(lastProviderId, rows.maxOfOrNull { it.first } ?: 0)
        saveCursor(context)
        rows.forEach { (_, m) -> firstSighting(m.address, m.body, m.timestampMs) }
        return rows.map { it.second }.reversed()
    }

    // ------------------------------------------------------------------ real-time

    /** ContentObserver on content://mms-sms/ catches messages sent from the phone itself and OEM writes. */
    fun observe(context: Context, onMessage: (SmsMessageEvent) -> Unit) {
        if (observer != null || !context.has(Manifest.permission.READ_SMS)) return
        // Resume from the persisted cursor so messages that arrived while we were dead are caught up.
        if (lastProviderId < 0) lastProviderId = prefs(context).getLong("last_sms_id", -1)
        if (lastProviderId < 0) lastProviderId = recent(context, limit = 1).firstOrNull()?.first ?: 0
        val handler = Handler(Looper.getMainLooper())
        observer = object : ContentObserver(handler) {
            override fun onChange(selfChange: Boolean) {
                val fresh = recent(context, limit = 50, afterId = lastProviderId)
                if (fresh.isEmpty()) return
                lastProviderId = fresh.maxOf { it.first }
                saveCursor(context)
                fresh.reversed().forEach { (_, m) ->
                    if (m.status != MessageStatus.PENDING && firstSighting(m.address, m.body, m.timestampMs)) onMessage(m)
                }
            }
        }
        context.contentResolver.registerContentObserver(Uri.parse("content://mms-sms/"), true, observer!!)
        observer!!.onChange(false) // catch-up pass
    }

    fun stopObserving(context: Context) {
        observer?.let { context.contentResolver.unregisterContentObserver(it) }
        observer = null
    }

    // ------------------------------------------------------------------ sending

    private val sendTimes = ArrayDeque<Long>()

    /** A Mac may send at most 20 texts per minute; limits damage from a compromised Mac or a runaway loop. */
    @Synchronized
    private fun allowSend(now: Long = System.currentTimeMillis()): Boolean {
        while (sendTimes.isNotEmpty() && now - sendTimes.first() > 60_000) sendTimes.removeFirst()
        if (sendTimes.size >= 20) return false
        sendTimes.addLast(now)
        return true
    }

    private val pending = mutableMapOf<String, IntArray>() // requestId -> [sentLeft, deliveredLeft, failed]

    @SuppressLint("MissingPermission")
    fun send(context: Context, cmd: SendSmsCommand): Result<Unit> = runCatching {
        check(context.has(Manifest.permission.SEND_SMS)) { "SEND_SMS permission not granted" }
        check(Phone.isPlainNumber(cmd.recipientAddress)) { "Refused: that isn't a plain phone number" }
        check(allowSend()) { "Too many messages sent from the Mac in the last minute" }
        val manager: SmsManager = if (Build.VERSION.SDK_INT >= 31) {
            context.getSystemService(SmsManager::class.java).createForSubscriptionId(cmd.subscriptionId)
        } else {
            @Suppress("DEPRECATION") SmsManager.getSmsManagerForSubscriptionId(cmd.subscriptionId)
        }
        val parts = manager.divideMessage(cmd.body)
        synchronized(pending) { pending[cmd.clientRequestId] = intArrayOf(parts.size, parts.size, 0) }
        // Pre-register so the provider echo isn't relayed back as a "new" outgoing message.
        firstSighting(cmd.recipientAddress, cmd.body, System.currentTimeMillis())

        fun intent(kind: String, part: Int): PendingIntent {
            val i = Intent(context, SmsStatusReceiver::class.java)
                .setAction("dev.phonepigeon.SMS_$kind")
                .putExtra("request_id", cmd.clientRequestId)
                .setData(Uri.parse("phonepigeon://sms/${cmd.clientRequestId}/$kind/$part"))
            return PendingIntent.getBroadcast(context, 0, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        val sent = ArrayList(parts.indices.map { intent("SENT", it) })
        val delivered = ArrayList(parts.indices.map { intent("DELIVERED", it) })
        if (parts.size == 1) manager.sendTextMessage(cmd.recipientAddress, null, cmd.body, sent[0], delivered[0])
        else manager.sendMultipartTextMessage(cmd.recipientAddress, null, parts, sent, delivered)
    }

    /** Aggregates per-part results into one status (spec §12: unified bubble for multipart). */
    fun onPartResult(requestId: String, kind: String, ok: Boolean): MessageStatus? = synchronized(pending) {
        val s = pending[requestId] ?: return null
        if (!ok) { pending.remove(requestId); return MessageStatus.FAILED }
        if (kind == "SENT") { s[0]--; if (s[0] == 0) return MessageStatus.SENT }
        else { s[1]--; if (s[1] == 0) { pending.remove(requestId); return MessageStatus.DELIVERED } }
        null
    }
}

/** SMS_RECEIVED broadcast — fastest path for incoming messages. */
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val parts = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        if (parts.isEmpty()) return
        val subId = intent.getIntExtra(SubscriptionManager.EXTRA_SUBSCRIPTION_INDEX,
            intent.getIntExtra("subscription", SubscriptionManager.getDefaultSmsSubscriptionId()))
        val address = Phone.normalize(context, parts[0].displayOriginatingAddress ?: return)
        val body = parts.joinToString("") { it.displayMessageBody ?: "" }
        val now = System.currentTimeMillis()
        if (!SmsRepository.firstSighting(address, body, now)) return
        RelayEngine.get(context).onLocalSms(
            SmsMessageEvent(UUID.randomUUID().toString(), SmsRepository.threadId(address), subId, address, body,
                MessageDirection.INCOMING, MessageStatus.DELIVERED, now, false)
        )
    }
}

/** SENT / DELIVERED PendingIntent results → SmsStatusUpdate back to the Mac. */
class SmsStatusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val requestId = intent.getStringExtra("request_id") ?: return
        val kind = if (intent.action?.endsWith("DELIVERED") == true) "DELIVERED" else "SENT"
        val ok = resultCode == Activity.RESULT_OK
        android.util.Log.d("PhonePigeon", "sms $kind result=$resultCode for $requestId")
        val status = SmsRepository.onPartResult(requestId, kind, ok) ?: return
        RelayEngine.get(context).onSmsStatus(requestId, status, if (ok) "" else "Carrier error $resultCode")
    }
}
