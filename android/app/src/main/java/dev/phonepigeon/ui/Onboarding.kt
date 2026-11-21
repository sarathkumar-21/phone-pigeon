package dev.phonepigeon.ui

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BatteryChargingFull
import androidx.compose.material.icons.rounded.Bluetooth
import androidx.compose.material.icons.rounded.FolderOpen
import androidx.compose.material.icons.rounded.PhotoLibrary
import android.os.Environment
import androidx.compose.material.icons.rounded.Call
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Contacts
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.Laptop
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.SimCard
import androidx.compose.material.icons.rounded.Sms
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import dev.phonepigeon.telephony.has
import dev.phonepigeon.ui.theme.Brand

@Composable
fun WelcomeScreen(onContinue: () -> Unit) {
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { shown = true }
    AuroraBackground {
        Column(
            Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(24.dp).verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(48.dp))
            Box(
                Modifier.size(96.dp).shadow(28.dp, RoundedCornerShape(28.dp), spotColor = Brand.Violet)
                    .clip(RoundedCornerShape(28.dp)).background(Brand.gradient),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Rounded.Laptop, null, tint = Color.White, modifier = Modifier.size(46.dp)) }
            Spacer(Modifier.height(28.dp))
            Text("Your phone,\non your Mac.", style = MaterialTheme.typography.displaySmall, textAlign = TextAlign.Center)
            Spacer(Modifier.height(10.dp))
            Text("Texts, calls and verification codes from every SIM — end-to-end encrypted.",
                style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
            Spacer(Modifier.height(32.dp))

            val features = listOf(
                Triple(Icons.Rounded.SimCard, "Dual-SIM aware", "Your Mac replies from the SIM each conversation uses.") to Color(0xFFFF9F43),
                Triple(Icons.Rounded.Lock, "Zero-knowledge", "X25519 + ChaCha20-Poly1305. Only your devices hold the keys.") to Brand.Green,
                Triple(Icons.Rounded.Key, "Codes in one click", "OTPs are detected on your Mac and copied instantly.") to Brand.Violet,
                Triple(Icons.Rounded.Call, "Calls from your Mac", "Dial, answer and talk through your Mac.") to Brand.Blue,
            )
            features.forEachIndexed { i, (f, tint) ->
                AnimatedVisibility(shown, enter = fadeIn(tween(400, 120 * i)) + slideInVertically(tween(400, 120 * i)) { it / 3 }) {
                    Card(Modifier.fillMaxWidth().padding(vertical = 5.dp), padding = 16.dp) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            IconBadge(f.first, tint)
                            Spacer(Modifier.width(14.dp))
                            Column {
                                Text(f.second, style = MaterialTheme.typography.titleMedium)
                                Text(f.third, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.weight(1f).height(28.dp))
            GradientButton("Get started", modifier = Modifier.fillMaxWidth(), onClick = onContinue)
        }
    }
}

private fun <T> tween(ms: Int, delay: Int) = androidx.compose.animation.core.tween<T>(ms, delay)

private data class PermGroup(val icon: ImageVector, val tint: Color, val title: String, val why: String, val perms: List<String>)

@Composable
fun PermissionsScreen(onContinue: () -> Unit) {
    val context = LocalContext.current
    var tick by remember { mutableIntStateOf(0) }
    // "Allow all" asks for every runtime permission in one go, then walks through the two Settings-screen permissions.
    var awaitingReturn by remember { mutableStateOf(false) }
    val settingsQueue = remember { mutableListOf<() -> Unit>() }
    fun runNextSetting() {
        val next = settingsQueue.removeFirstOrNull()
        if (next == null) { awaitingReturn = false; return }
        awaitingReturn = true
        next()
    }
    LifecycleResumeEffect(Unit) { tick++; if (awaitingReturn) runNextSetting(); onPauseOrDispose { } }

    val groups = buildList {
        add(PermGroup(Icons.Rounded.Sms, Brand.Blue, "Messages", "Read, receive and send SMS on each SIM",
            listOf(Manifest.permission.READ_SMS, Manifest.permission.SEND_SMS, Manifest.permission.RECEIVE_SMS, Manifest.permission.RECEIVE_MMS)))
        add(PermGroup(Icons.Rounded.Call, Brand.Green, "Phone & SIMs", "Detect SIMs, place and answer calls",
            listOf(Manifest.permission.READ_PHONE_STATE, Manifest.permission.READ_PHONE_NUMBERS, Manifest.permission.CALL_PHONE,
                Manifest.permission.READ_CALL_LOG, Manifest.permission.ANSWER_PHONE_CALLS)))
        add(PermGroup(Icons.Rounded.Contacts, Color(0xFFFF9F43), "Contacts", "Show names and photos on your Mac",
            listOf(Manifest.permission.READ_CONTACTS)))
        if (Build.VERSION.SDK_INT >= 33) add(PermGroup(Icons.Rounded.Notifications, Brand.Violet, "Notifications",
            "Keep the connection status visible", listOf(Manifest.permission.POST_NOTIFICATIONS)))
        add(PermGroup(Icons.Rounded.PhotoLibrary, Color(0xFF14B8A6), "Photos & videos", "Browse and stream your gallery on the Mac",
            if (Build.VERSION.SDK_INT >= 33) listOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
            else listOf(Manifest.permission.READ_EXTERNAL_STORAGE)))
        if (Build.VERSION.SDK_INT >= 31) add(PermGroup(Icons.Rounded.Bluetooth, Color(0xFF0EA5E9), "Bluetooth",
            "Talk through your Mac during calls", listOf(Manifest.permission.BLUETOOTH_CONNECT)))
    }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { tick++ }
    val power: PowerManager? = context.getSystemService(PowerManager::class.java)
    val allLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { tick++; runNextSetting() }

    fun openAllFiles() {
        // Some tablets and OEM builds lack the dedicated screen: fall back to the app's settings page.
        runCatching { context.startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:${context.packageName}"))) }
            .recoverCatching { context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))) }
    }
    fun openNotificationAccess() {
        runCatching { context.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) }
    }
    fun openBattery() {
        @Suppress("BatteryLife")
        runCatching { context.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}"))) }
            .recoverCatching { context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))) }
    }
    fun allowAll() {
        settingsQueue.clear()
        if (Build.VERSION.SDK_INT >= 30 && !Environment.isExternalStorageManager()) settingsQueue += ::openAllFiles
        if (!dev.phonepigeon.service.NotificationMirrorService.isEnabled(context)) settingsQueue += ::openNotificationAccess
        if (power?.isIgnoringBatteryOptimizations(context.packageName) == false) settingsQueue += ::openBattery
        val missing = groups.flatMap { it.perms }.filterNot(context::has).distinct()
        if (missing.isNotEmpty()) allLauncher.launch(missing.toTypedArray()) else runNextSetting()
    }

    Column(
        Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).statusBarsPadding().navigationBarsPadding()
            .padding(horizontal = 20.dp).verticalScroll(rememberScrollState()),
    ) {
        Spacer(Modifier.height(28.dp))
        Text("A few permissions", style = MaterialTheme.typography.headlineMedium)
        Spacer(Modifier.height(6.dp))
        Text("PhonePigeon only shares data with your paired Mac, encrypted end-to-end. Nothing is readable by our servers.",
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(20.dp))

        @Suppress("UNUSED_EXPRESSION") tick
        val anyMissing = groups.any { g -> !g.perms.all(context::has) } ||
            (Build.VERSION.SDK_INT >= 30 && !Environment.isExternalStorageManager()) ||
            power?.isIgnoringBatteryOptimizations(context.packageName) == false ||
            !dev.phonepigeon.service.NotificationMirrorService.isEnabled(context)
        if (anyMissing) {
            GradientButton("Allow all", icon = Icons.Rounded.CheckCircle, modifier = Modifier.fillMaxWidth(), onClick = ::allowAll)
            Spacer(Modifier.height(4.dp))
            Text("Asks for everything below in one go. Android may still show a few screens for files and battery.",
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(14.dp))
        }

        groups.forEach { g ->
            @Suppress("UNUSED_EXPRESSION") tick
            val granted = g.perms.all(context::has)
            PermissionRow(g.icon, g.tint, g.title, g.why, granted) { launcher.launch(g.perms.toTypedArray()) }
        }
        if (Build.VERSION.SDK_INT >= 30) {
            val allFiles = remember(tick) { Environment.isExternalStorageManager() }
            PermissionRow(Icons.Rounded.FolderOpen, Color(0xFFF59E0B), "All files access", "Browse, upload and manage phone files from Finder", allFiles) {
                openAllFiles()
            }
        }
        val notifAccess = remember(tick) { dev.phonepigeon.service.NotificationMirrorService.isEnabled(context) }
        PermissionRow(Icons.Rounded.Notifications, Brand.Violet, "Notification access", "Show your phone's notifications on your Mac", notifAccess) {
            openNotificationAccess()
        }
        val ignoring = remember(tick) { power?.isIgnoringBatteryOptimizations(context.packageName) ?: true }
        PermissionRow(Icons.Rounded.BatteryChargingFull, Color(0xFF14B8A6), "Battery", "Stay connected while the screen is off", ignoring) {
            openBattery()
        }

        Spacer(Modifier.height(24.dp))
        val allCore = remember(tick) { groups.take(2).all { g -> g.perms.all(context::has) } }
        GradientButton(if (allCore) "Continue" else "Continue anyway", icon = Icons.Rounded.Link,
            modifier = Modifier.fillMaxWidth(), onClick = onContinue)
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun PermissionRow(icon: ImageVector, tint: Color, title: String, why: String, granted: Boolean, onGrant: () -> Unit) {
    Card(Modifier.fillMaxWidth().padding(vertical = 5.dp), padding = 14.dp) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconBadge(icon, tint, 42.dp)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleMedium)
                Text(why, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Spacer(Modifier.width(8.dp))
            if (granted) Icon(Icons.Rounded.CheckCircle, "Granted", tint = Brand.Green, modifier = Modifier.size(28.dp))
            else FilledTonalButton(onClick = onGrant) { Text("Allow") }
        }
    }
}
