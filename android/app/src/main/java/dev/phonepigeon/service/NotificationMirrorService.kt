package dev.phonepigeon.service

import android.app.Notification
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.provider.Telephony
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.telecom.TelecomManager
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
 * Left out on purpose: PhonePigeon's own, ongoing ones (calls, music, navigation), group summaries, and the SMS and
 * dialer apps (messages and calls already reach the Mac natively, so they would show twice).
 */
class NotificationMirrorService : NotificationListenerService() {
    companion object {
        @Volatile var instance: NotificationMirrorService? = null
            private set

        fun isEnabled(context: Context): Boolean =
            NotificationManagerCompat.getEnabledListenerPackages(context).contains(context.packageName)

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

    override fun onListenerDisconnected() { instance = null }

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
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        if (sbn.isOngoing || n.flags and Notification.FLAG_ONGOING_EVENT != 0) return
        if (n.category == Notification.CATEGORY_TRANSPORT || n.category == Notification.CATEGORY_CALL) return
        if (pkg == Telephony.Sms.getDefaultSmsPackage(this) || pkg == getSystemService(TelecomManager::class.java)?.defaultDialerPackage) return

        val extras = n.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty()
        if (title.isBlank() && text.isBlank()) return

        val appName = runCatching { packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString() }.getOrDefault(pkg)
        val icon = if (iconsSent.add(pkg)) appIcon(pkg) else ""
        engine.sendFromService(PayloadBody(notification = NotificationEvent(
            key = sbn.key, packageName = pkg, appName = appName, title = title, text = text.take(2000),
            subText = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString().orEmpty(),
            postedAtMs = sbn.postTime, appIconPng = icon, canDismiss = sbn.isClearable)))
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
