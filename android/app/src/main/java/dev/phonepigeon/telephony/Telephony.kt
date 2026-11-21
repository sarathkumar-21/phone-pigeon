package dev.phonepigeon.telephony

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.os.Environment
import android.os.StatFs
import android.os.BatteryManager
import android.provider.ContactsContract
import android.telephony.PhoneNumberUtils
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import dev.phonepigeon.proto.ContactEntry
import dev.phonepigeon.proto.DeviceStatusEvent
import dev.phonepigeon.proto.SimCard
import java.io.ByteArrayOutputStream
import java.util.Locale

fun Context.has(permission: String) =
    ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

object Phone {
    private val dialable = Regex("^\\+?[0-9 ()./-]{3,24}$")

    /**
     * Numbers the Mac may ask this phone to call or text. Digits, spaces and common separators only:
     * `*` and `#` are rejected because `*21*number#`-style strings are carrier codes (call forwarding, USSD), not numbers.
     */
    fun isPlainNumber(raw: String): Boolean = dialable.matches(raw.trim()) && raw.count { it.isDigit() } >= 3

    /** Best-effort E.164 normalisation using the SIM / network country. Alphanumeric senders pass through. */
    private val normalized = object : java.util.LinkedHashMap<String, String>(256, 0.75f, true) {
        override fun removeEldestEntry(e: MutableMap.MutableEntry<String, String>?) = size > 2000
    }

    /** Cached: a 500-message sync repeats the same few hundred addresses, and each lookup hits TelephonyManager. */
    @Synchronized
    fun normalize(context: Context, raw: String): String =
        normalized.getOrPut(raw) { normalizeUncached(context, raw) }

    private fun normalizeUncached(context: Context, raw: String): String {
        val trimmed = raw.trim()
        if (trimmed.any { it.isLetter() }) return trimmed
        val tm = context.getSystemService(TelephonyManager::class.java)
        val iso = (tm?.networkCountryIso?.takeIf { it.isNotEmpty() } ?: tm?.simCountryIso ?: Locale.getDefault().country)
            .uppercase(Locale.US)
        PhoneNumberUtils.formatNumberToE164(trimmed, iso)?.let { return it }
        val digits = trimmed.filter { it.isDigit() }
        return if (trimmed.startsWith("+")) "+$digits" else digits
    }

    /** The caller's contact photo as a small JPEG (about 300 px, at most ~40 KB), or null. Sent once per call. */
    fun contactPhoto(context: Context, number: String): ByteArray? {
        if (!context.has(Manifest.permission.READ_CONTACTS) || number.isBlank()) return null
        val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number))
        return runCatching {
            val photoUri = context.contentResolver.query(uri, arrayOf(ContactsContract.PhoneLookup.PHOTO_URI), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            } ?: return null
            val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            context.contentResolver.openInputStream(Uri.parse(photoUri))?.use { BitmapFactory.decodeStream(it, null, opts) }
            var sample = 1
            while (opts.outWidth / (sample * 2) >= 320 && opts.outHeight / (sample * 2) >= 320) sample *= 2
            val bmp = context.contentResolver.openInputStream(Uri.parse(photoUri))?.use {
                BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
            } ?: return null
            val side = minOf(bmp.width, bmp.height)
            val square = Bitmap.createBitmap(bmp, (bmp.width - side) / 2, (bmp.height - side) / 2, side, side)
            val scaled = if (side > 320) Bitmap.createScaledBitmap(square, 320, 320, true) else square
            var quality = 80
            var bytes: ByteArray
            do {
                bytes = ByteArrayOutputStream().also { scaled.compress(Bitmap.CompressFormat.JPEG, quality, it) }.toByteArray()
                quality -= 15
            } while (bytes.size > 40_000 && quality >= 35)
            bytes.takeIf { it.size <= 60_000 }
        }.getOrNull()
    }

    fun contactName(context: Context, number: String): String? {
        if (!context.has(Manifest.permission.READ_CONTACTS) || number.isBlank()) return null
        val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number))
        return runCatching {
            context.contentResolver.query(uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            }
        }.getOrNull()
    }
}

/** Multi-SIM inventory (spec §8.2.1). */
object SimInventory {
    private val palette = listOf("#3B6CFF", "#FF5B3A", "#22B07D", "#A259FF")

    @SuppressLint("MissingPermission", "HardwareIds")
    fun read(context: Context): List<SimCard> {
        if (!context.has(Manifest.permission.READ_PHONE_STATE)) return emptyList()
        val sm = context.getSystemService(SubscriptionManager::class.java) ?: return emptyList()
        val subs = sm.activeSubscriptionInfoList ?: return emptyList()
        val defaultSms = SubscriptionManager.getDefaultSmsSubscriptionId()
        val defaultVoice = SubscriptionManager.getDefaultVoiceSubscriptionId()
        return subs.sortedBy { it.simSlotIndex }.map { info ->
            val number = runCatching {
                if (android.os.Build.VERSION.SDK_INT >= 33) sm.getPhoneNumber(info.subscriptionId) else @Suppress("DEPRECATION") info.number
            }.getOrNull().orEmpty()
            SimCard(
                subscriptionId = info.subscriptionId,
                slotIndex = info.simSlotIndex.coerceAtLeast(0),
                carrierName = info.carrierName?.toString()?.takeIf { it.isNotBlank() } ?: "SIM ${info.simSlotIndex + 1}",
                displayName = info.displayName?.toString() ?: "",
                phoneNumber = if (number.isNotBlank()) Phone.normalize(context, number) else "",
                accentColorHex = palette[info.simSlotIndex.coerceIn(0, palette.lastIndex)],
                isDefaultSms = info.subscriptionId == defaultSms,
                isDefaultVoice = info.subscriptionId == defaultVoice,
            )
        }
    }

    fun listen(context: Context, onChange: () -> Unit): SubscriptionManager.OnSubscriptionsChangedListener? {
        val sm = context.getSystemService(SubscriptionManager::class.java) ?: return null
        val l = object : SubscriptionManager.OnSubscriptionsChangedListener() {
            override fun onSubscriptionsChanged() = onChange()
        }
        runCatching { sm.addOnSubscriptionsChangedListener(ContextCompat.getMainExecutor(context), l) }
        return l
    }
}

/** Contacts (spec ContactSyncBatch) with 64×64 JPEG thumbnails. */
object ContactsReader {
    fun read(context: Context): List<ContactEntry> {
        if (!context.has(Manifest.permission.READ_CONTACTS)) return emptyList()
        val byId = LinkedHashMap<String, Triple<String, MutableSet<String>, String?>>()
        val projection = arrayOf(
            ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
            ContactsContract.CommonDataKinds.Phone.NUMBER,
            ContactsContract.CommonDataKinds.Phone.PHOTO_THUMBNAIL_URI,
        )
        context.contentResolver.query(ContactsContract.CommonDataKinds.Phone.CONTENT_URI, projection, null, null,
            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME + " ASC")?.use { c ->
            while (c.moveToNext()) {
                val id = c.getString(0) ?: continue
                val name = c.getString(1) ?: continue
                val number = c.getString(2) ?: continue
                val entry = byId.getOrPut(id) { Triple(name, linkedSetOf(), c.getString(3)) }
                entry.second += Phone.normalize(context, number)
            }
        }
        return byId.map { (id, v) ->
            ContactEntry(id, v.first, v.second.toList(), v.third?.let { thumbnail(context, it) })
        }
    }

    private fun thumbnail(context: Context, uri: String): ByteArray? = runCatching {
        context.contentResolver.openInputStream(Uri.parse(uri))?.use { input ->
            val bmp = BitmapFactory.decodeStream(input) ?: return null
            val scaled = Bitmap.createScaledBitmap(bmp, 64, 64, true)
            ByteArrayOutputStream().also { scaled.compress(Bitmap.CompressFormat.JPEG, 70, it) }.toByteArray()
        }
    }.getOrNull()
}

object DeviceStatusReader {
    /** Battery, Bluetooth HFP link to the Mac and storage usage (spec v2 DeviceStatusEvent). */
    @SuppressLint("MissingPermission")
    fun read(context: Context): DeviceStatusEvent {
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
        val hfp = runCatching {
            val canAsk = android.os.Build.VERSION.SDK_INT < 31 || context.has(Manifest.permission.BLUETOOTH_CONNECT)
            canAsk && context.getSystemService(BluetoothManager::class.java)?.adapter
                ?.getProfileConnectionState(BluetoothProfile.HEADSET) == BluetoothProfile.STATE_CONNECTED
        }.getOrDefault(false)
        val stat = runCatching { StatFs(Environment.getExternalStorageDirectory().path) }.getOrNull()
        return DeviceStatusEvent(
            batteryPercent = if (level >= 0) (level * 100 / scale) else 0,
            isCharging = charging,
            bluetoothHfpConnected = hfp,
            storageFreeBytes = stat?.availableBytes ?: 0,
            storageTotalBytes = stat?.totalBytes ?: 0,
        )
    }
}


/** Looks in the call log for how a call the Mac placed ended: how long it was connected, 0 if nobody answered. */
object CallOutcome {
    @SuppressLint("MissingPermission")
    fun durationSeconds(context: Context, number: String, notBeforeMs: Long): Int? {
        if (!context.has(Manifest.permission.READ_CALL_LOG)) return null
        val digits = number.filter { it.isDigit() }
        if (digits.length < 3) return null
        val tail = digits.takeLast(7)
        return runCatching {
            context.contentResolver.query(
                android.provider.CallLog.Calls.CONTENT_URI,
                arrayOf(android.provider.CallLog.Calls.NUMBER, android.provider.CallLog.Calls.DURATION),
                "${android.provider.CallLog.Calls.TYPE} = ? AND ${android.provider.CallLog.Calls.DATE} >= ?",
                arrayOf(android.provider.CallLog.Calls.OUTGOING_TYPE.toString(), (notBeforeMs - 5_000).toString()),
                "${android.provider.CallLog.Calls.DATE} DESC",
            )?.use { c ->
                var seen = 0
                while (c.moveToNext() && seen++ < 10) {
                    val n = c.getString(0)?.filter { it.isDigit() } ?: continue
                    if (n.endsWith(tail)) return c.getInt(1)
                }
                null
            }
        }.getOrNull()
    }
}
