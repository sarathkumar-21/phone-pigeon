package dev.phonepigeon.service

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.os.Bundle
import android.graphics.Bitmap
import android.graphics.Canvas
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import dev.phonepigeon.proto.NotificationEvent
import dev.phonepigeon.proto.NotificationRemoved
import dev.phonepigeon.proto.PayloadBody
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap

/**
 * Mirrors the phone's notifications to the paired Mac. Android only delivers them after the user turns on
 * "Notification access" for PhonePigeon in system settings; the Home screen also has an on/off switch.
 *
 * Left out on purpose: PhonePigeon's own, ongoing ones (calls, music, navigation) and group summaries that only repeat
 * their children. Everything else goes, including the SMS app's (RCS chats never reach the Mac as SMS; the Mac hides the
 * banner when the same text already arrived as a normal message).
 */
class NotificationMirrorService : NotificationListenerService() {
    companion object {
        @Volatile var instance: NotificationMirrorService? = null
            private set

        fun isEnabled(context: Context): Boolean =
            NotificationManagerCompat.getEnabledListenerPackages(context).contains(context.packageName)

        /**
         * Phones that save battery (vivo, Xiaomi, Huawei…) can unbind a listener without telling anyone, and Android only
         * binds it again when asked. Called whenever the app or the Mac link comes up.
         */
        fun ensureBound(context: Context) {
            if (isEnabled(context) && instance == null) {
                runCatching { requestRebind(ComponentName(context, NotificationMirrorService::class.java)) }
            }
        }

        /**
         * The Mac (re)connected: send what is in the shade again, with every app icon, because a Mac that restarted has
         * forgotten the icons and this service would otherwise only send each one once per run.
         */
        fun resync() { instance?.resyncAll() }

        /** Mac asked to clear one on the phone. */
        fun dismiss(key: String) { runCatching { instance?.cancelNotification(key) } }
    }

    private val iconsSent = ConcurrentHashMap.newKeySet<String>()
    private val engine by lazy { RelayEngine.get(this) }

    override fun onListenerConnected() {
        instance = this
        iconsSent.clear()
        // Catch the Mac up with what is already in the shade.
        runCatching { activeNotifications?.forEach(::mirror) }
    }

    fun resyncAll() {
        iconsSent.clear()
        runCatching { activeNotifications?.forEach(::mirror) }
    }

    override fun onListenerDisconnected() {
        instance = null
        ensureBound(this)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) = mirror(sbn)

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (engine.store.pairing == null || !engine.store.shareNotifications) return
        engine.sendFromService(PayloadBody(notificationRemoved = NotificationRemoved(sbn.key)))
    }

    private fun mirror(sbn: StatusBarNotification) {
        if (engine.store.pairing == null || !engine.store.shareNotifications) return
        val n = sbn.notification ?: return
        val pkg = sbn.packageName
        if (pkg == packageName) return
        // A group summary only repeats its children: skip it when they are there, keep it when it is all there is.
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) {
            val hasChildren = runCatching {
                activeNotifications?.any { it.key != sbn.key && it.groupKey == sbn.groupKey && it.notification.flags and Notification.FLAG_GROUP_SUMMARY == 0 }
            }.getOrNull() == true
            if (hasChildren) return
        }
        if (sbn.isOngoing || n.flags and Notification.FLAG_ONGOING_EVENT != 0) return
        if (n.category == Notification.CATEGORY_TRANSPORT || n.category == Notification.CATEGORY_CALL) return

        val extras = n.extras
        val title = bestTitle(extras)
        val text = bestText(n, extras)
        if (title.isBlank() && text.isBlank()) { Log.d("PhonePigeon", "notification from $pkg has no text, skipped"); return }

        val appName = runCatching { packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString() }.getOrDefault(pkg)
        val icon = if (iconsSent.add(pkg)) appIcon(pkg) else ""
        engine.sendFromService(PayloadBody(notification = NotificationEvent(
            key = sbn.key, packageName = pkg, appName = appName, title = title, text = text.take(2000),
            subText = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString().orEmpty(),
            postedAtMs = sbn.postTime, appIconPng = icon, canDismiss = sbn.isClearable)))
    }

    private fun bestTitle(e: Bundle): String =
        listOf(Notification.EXTRA_TITLE, Notification.EXTRA_TITLE_BIG, Notification.EXTRA_CONVERSATION_TITLE)
            .firstNotNullOfOrNull { e.getCharSequence(it)?.toString()?.takeIf(String::isNotBlank) }.orEmpty()

    /** Chat apps often leave EXTRA_TEXT empty and put the words in the messaging or inbox style instead. */
    @Suppress("DEPRECATION")
    private fun bestText(n: Notification, e: Bundle): String {
        e.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()?.takeIf(String::isNotBlank)?.let { return it }
        e.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.takeIf(String::isNotBlank)?.let { return it }
        runCatching {
            e.getParcelableArray(Notification.EXTRA_MESSAGES)?.mapNotNull { (it as? Bundle)?.getCharSequence("text")?.toString() }
                ?.filter(String::isNotBlank)?.takeLast(5)?.joinToString("\n")
        }.getOrNull()?.takeIf(String::isNotBlank)?.let { return it }
        e.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.joinToString("\n") { it.toString() }?.takeIf(String::isNotBlank)?.let { return it }
        e.getCharSequence(Notification.EXTRA_SUMMARY_TEXT)?.toString()?.takeIf(String::isNotBlank)?.let { return it }
        return n.tickerText?.toString().orEmpty()
    }

    private fun appIcon(pkg: String): String = runCatching {
        val d = packageManager.getApplicationIcon(pkg)
        val bmp = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888)
        d.setBounds(0, 0, 64, 64); d.draw(Canvas(bmp))
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    }.getOrElse { Log.w("PhonePigeon", "icon for $pkg failed: ${it.message}"); "" }
}
