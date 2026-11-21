package dev.phonepigeon.ui

import android.text.format.DateUtils
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.CallReceived
import androidx.compose.material.icons.rounded.Call
import androidx.compose.material.icons.rounded.Cast
import androidx.compose.material.icons.rounded.Contacts
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.TouchApp
import androidx.compose.material.icons.rounded.DeleteForever
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Upload
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Laptop
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.LinkOff
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Outbox
import androidx.compose.material.icons.rounded.Sms
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.Wifi
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.phonepigeon.proto.CallState
import dev.phonepigeon.service.Activity
import dev.phonepigeon.service.ActivityKind
import dev.phonepigeon.service.EngineState
import dev.phonepigeon.service.RelayEngine
import dev.phonepigeon.ui.theme.Brand
import kotlinx.coroutines.delay

@Composable
fun HomeScreen(state: EngineState, engine: RelayEngine) {
    var menu by remember { mutableStateOf(false) }
    var confirmUnpair by remember { mutableStateOf(false) }

    LazyColumn(
        Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background),
        contentPadding = PaddingValues(start = 18.dp, end = 18.dp, bottom = 32.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Row(Modifier.statusBarsPadding().padding(top = 10.dp, bottom = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("PhonePigeon", style = MaterialTheme.typography.headlineMedium, modifier = Modifier.weight(1f))
                Box {
                    IconButton(onClick = { menu = true }) { Icon(Icons.Rounded.MoreVert, "More") }
                    DropdownMenu(menu, { menu = false }) {
                        DropdownMenuItem({ Text("Resync everything") }, leadingIcon = { Icon(Icons.Rounded.Sync, null) },
                            onClick = { menu = false; engine.fullSync() })
                        DropdownMenuItem({ Text("Unpair Mac") }, leadingIcon = { Icon(Icons.Rounded.LinkOff, null) },
                            onClick = { menu = false; confirmUnpair = true })
                    }
                }
            }
        }
        item { HeroCard(state) }

        item {
            AnimatedVisibility(state.activeCall != null, enter = expandVertically() + fadeIn(), exit = shrinkVertically() + fadeOut()) {
                state.activeCall?.let { call ->
                    Card(padding = 16.dp) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            IconBadge(Icons.Rounded.Call, Brand.Green)
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text(call.contactName.ifBlank { call.remoteAddress }, style = MaterialTheme.typography.titleMedium)
                                Text(when (call.state) {
                                    CallState.RINGING_INCOMING -> "Ringing on your Mac too"
                                    CallState.DIALING_OUTGOING -> "Dialing from your Mac…"
                                    else -> "Live on your Mac" + if (call.isMuted) " · Muted" else ""
                                }, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
        }

        if (state.sims.isNotEmpty()) {
            item { SectionTitle("SIM cards") }
            item {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(state.sims, key = { it.subscriptionId }) {
                        SimTile(it, if (state.sims.size == 1) Modifier.fillParentMaxWidth() else Modifier.width(280.dp))
                    }
                }
            }
        }

        item {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Stat(Modifier.weight(1f), "${state.relayed}", "Messages relayed", Icons.Rounded.Sms, Brand.Blue)
                Stat(Modifier.weight(1f), if (state.pairedAt > 0) DateUtils.getRelativeTimeSpanString(state.pairedAt).toString() else "—",
                    "Paired", Icons.Rounded.Link, Brand.Violet)
            }
        }

        item { SectionTitle("Share with Mac") }
        item {
            Card(padding = 6.dp) {
                ShareRow(Icons.Rounded.Sms, Brand.Blue, "Messages", "SMS from every SIM, with OTP detection", state.shareSms) { engine.setShare(sms = it) }
                HorizontalDivider(Modifier.padding(start = 66.dp), color = MaterialTheme.colorScheme.outlineVariant)
                ShareRow(Icons.Rounded.Call, Brand.Green, "Calls", "Ring, answer and dial from your Mac", state.shareCalls) { engine.setShare(calls = it) }
                HorizontalDivider(Modifier.padding(start = 66.dp), color = MaterialTheme.colorScheme.outlineVariant)
                ShareRow(Icons.Rounded.Contacts, Color(0xFFFF9F43), "Contacts", "Names and photos", state.shareContacts) { engine.setShare(contacts = it) }
                HorizontalDivider(Modifier.padding(start = 66.dp), color = MaterialTheme.colorScheme.outlineVariant)
                ShareRow(Icons.Rounded.Notifications, Brand.Violet, "Notifications", "Show this phone's notifications on your Mac", state.shareNotifications) { engine.setShare(notifications = it) }
                if (state.shareNotifications) {
                    val ctx = androidx.compose.ui.platform.LocalContext.current
                    val enabled = dev.phonepigeon.service.NotificationMirrorService.isEnabled(ctx)
                    val connected = dev.phonepigeon.service.NotificationMirrorService.instance != null
                    if (!enabled) {
                        SettingsLink("Allow notification access", "Android needs you to switch PhonePigeon on in its list.",
                            android.provider.Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                    } else if (!connected) {
                        SettingsLink("Notification access is on but not running", "Switch PhonePigeon off and on again in the list, then reopen this app.",
                            android.provider.Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                    }
                    androidx.compose.material3.TextButton(
                        onClick = { engine.sendTestNotification() },
                        modifier = Modifier.padding(start = 56.dp),
                    ) { Text("Send a test notification to the Mac") }
                }
            }
        }

        item { SectionTitle("Mac access to files") }
        item {
            Card(padding = 6.dp) {
                ShareRow(Icons.Rounded.Folder, Brand.Violet, "Browse and copy", "Photos, videos and files, read-only", state.filesRead) { engine.setShare(filesRead = it) }
                HorizontalDivider(Modifier.padding(start = 66.dp), color = MaterialTheme.colorScheme.outlineVariant)
                ShareRow(Icons.Rounded.Upload, Brand.Blue, "Upload and rename", "Add files, make folders, rename", state.filesWrite) { engine.setShare(filesWrite = it) }
                HorizontalDivider(Modifier.padding(start = 66.dp), color = MaterialTheme.colorScheme.outlineVariant)
                ShareRow(Icons.Rounded.DeleteForever, Color(0xFFE5484D), "Delete", "Let the Mac delete files from this phone", state.filesDelete) { engine.setShare(filesDelete = it) }
                HorizontalDivider(Modifier.padding(start = 66.dp), color = MaterialTheme.colorScheme.outlineVariant)
                ShareRow(Icons.Rounded.Cast, Color(0xFF14B8A6), "Screen mirroring", "Show this screen on the Mac (you approve each time)", state.screenMirror) { engine.setShare(screen = it) }
                HorizontalDivider(Modifier.padding(start = 66.dp), color = MaterialTheme.colorScheme.outlineVariant)
                ShareRow(Icons.Rounded.TouchApp, Color(0xFFE5484D), "Remote control", "Let the Mac tap, swipe and type while mirroring", state.remoteControl) { engine.setShare(remoteControl = it) }
                if (state.remoteControl && dev.phonepigeon.service.RemoteControlService.instance == null) {
                    SettingsLink("Turn on the accessibility service", "Find “PhonePigeon remote control” and switch it on. Android shows a warning; it only acts while mirroring runs.",
                        android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
                }
            }
        }

        item { SectionTitle("Activity") }
        if (state.activity.isEmpty()) {
            item {
                Card { Text("Messages and calls relayed to your Mac will show up here.", color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
        } else item {
            Card(Modifier.animateContentSize(), padding = 6.dp) {
                state.activity.take(12).forEachIndexed { i, a ->
                    ActivityRow(a)
                    if (i < minOf(11, state.activity.lastIndex)) HorizontalDivider(Modifier.padding(start = 58.dp), color = MaterialTheme.colorScheme.outlineVariant)
                }
            }
        }

        item { Spacer(Modifier.navigationBarsPadding()) }
    }

    if (confirmUnpair) AlertDialog(
        onDismissRequest = { confirmUnpair = false },
        title = { Text("Unpair ${state.macName}?") },
        text = { Text("Your Mac will stop receiving messages and calls from this phone. Nothing on the phone is deleted.") },
        confirmButton = { TextButton(onClick = { confirmUnpair = false; engine.unpair() }) { Text("Unpair", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { confirmUnpair = false }) { Text("Cancel") } },
    )
}

@Composable
private fun HeroCard(s: EngineState) {
    Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(28.dp)).background(Brand.gradient)) {
        Canvas(Modifier.matchParentSize()) {
            drawCircle(Color.White.copy(alpha = 0.10f), size.width * 0.42f, Offset(size.width * 0.95f, size.height * 0.05f))
            drawCircle(Color.White.copy(alpha = 0.07f), size.width * 0.28f, Offset(size.width * 0.05f, size.height * 1.05f))
        }
        Column(Modifier.padding(22.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(52.dp).clip(RoundedCornerShape(16.dp)).background(Color.White.copy(alpha = 0.2f)), contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.Laptop, null, tint = Color.White, modifier = Modifier.size(28.dp))
                }
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text("Paired Mac", color = Color.White.copy(alpha = 0.8f), style = MaterialTheme.typography.labelMedium)
                    Text(s.macName, color = Color.White, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, maxLines = 1)
                }
            }
            Spacer(Modifier.height(18.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                StatusPill(s.connection)
                Spacer(Modifier.width(10.dp))
                s.lanHost?.takeIf { s.connection == dev.phonepigeon.service.Connection.LAN }?.let {
                    Icon(Icons.Rounded.Wifi, null, tint = Color.White.copy(alpha = 0.8f), modifier = Modifier.size(15.dp))
                    Spacer(Modifier.width(4.dp))
                    Text(it, color = Color.White.copy(alpha = 0.85f), style = MaterialTheme.typography.labelMedium, fontFamily = FontFamily.Monospace)
                }
            }
        }
    }
}

@Composable
private fun Stat(modifier: Modifier, value: String, label: String, icon: ImageVector, tint: Color) {
    Card(modifier, padding = 16.dp) {
        IconBadge(icon, tint, 34.dp)
        Spacer(Modifier.height(10.dp))
        Text(value, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, maxLines = 1)
        Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** A row that opens one of Android's settings pages (access that can't be granted from a dialog). */
@Composable
private fun SettingsLink(title: String, detail: String, action: String) {
    val context = androidx.compose.ui.platform.LocalContext.current
    Column(Modifier.fillMaxWidth().padding(start = 66.dp, end = 12.dp, bottom = 10.dp)) {
        Text(detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        androidx.compose.material3.TextButton(onClick = {
            runCatching { context.startActivity(android.content.Intent(action).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)) }
        }) { Text(title) }
    }
}

@Composable
private fun ShareRow(icon: ImageVector, tint: Color, title: String, sub: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        IconBadge(icon, tint, 38.dp)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(sub, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked, onChange, colors = SwitchDefaults.colors(checkedTrackColor = Brand.Violet))
    }
}

@Composable
private fun ActivityRow(a: Activity) {
    val (icon, tint) = when (a.kind) {
        ActivityKind.SMS_IN -> Icons.AutoMirrored.Rounded.CallReceived to Brand.Blue
        ActivityKind.SMS_OUT -> Icons.Rounded.Outbox to Brand.Violet
        ActivityKind.CALL -> Icons.Rounded.Call to Brand.Green
        ActivityKind.SYNC -> Icons.Rounded.Sync to Brand.Cyan
        ActivityKind.LINK -> Icons.Rounded.Link to Color(0xFFFF9F43)
        ActivityKind.ERROR -> Icons.Rounded.ErrorOutline to Color(0xFFEF4444)
    }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(30_000); now = System.currentTimeMillis() } }
    Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(32.dp).clip(CircleShape).background(tint.copy(alpha = 0.14f)), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = tint, modifier = Modifier.size(17.dp))
        }
        Spacer(Modifier.width(14.dp))
        Text(a.text, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f), maxLines = 2)
        Text(DateUtils.getRelativeTimeSpanString(a.at, now, DateUtils.MINUTE_IN_MILLIS).toString(),
            style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun Fingerprint(label: String, value: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
        Text(value, fontFamily = FontFamily.Monospace, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
}
