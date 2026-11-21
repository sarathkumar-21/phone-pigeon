package dev.phonepigeon

import android.app.Application
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.phonepigeon.service.RelayEngine
import dev.phonepigeon.service.RelayForegroundService
import dev.phonepigeon.ui.HomeScreen
import dev.phonepigeon.ui.PairScreen
import dev.phonepigeon.ui.PermissionsScreen
import dev.phonepigeon.ui.WelcomeScreen
import dev.phonepigeon.ui.theme.PhonePigeonTheme

class PhonePigeonApp : Application() {
    override fun onCreate() {
        super.onCreate()
        CrashReporter.install(this)
        RelayForegroundService.createChannel(this)
        // The foreground service is started from the activity / boot receiver only:
        // this process may also be launched in the background by an SMS broadcast.
    }
}

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val engine = RelayEngine.get(this)
        if (engine.store.pairing != null) engine.startService()
        setContent {
            PhonePigeonTheme {
                var crash by remember { mutableStateOf(CrashReporter.pending(this@MainActivity)) }
                crash?.let { report ->
                    AlertDialog(
                        onDismissRequest = { CrashReporter.clear(this@MainActivity); crash = null },
                        title = { Text("PhonePigeon closed unexpectedly") },
                        text = {
                            Column {
                                Text("Please send this to the developer so it can be fixed. It has no messages, numbers or keys in it.")
                                Spacer(Modifier.height(8.dp))
                                Text(report.take(1200), style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace,
                                    modifier = Modifier.heightIn(max = 220.dp).verticalScroll(rememberScrollState()))
                            }
                        },
                        confirmButton = {
                            TextButton(onClick = {
                                startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain")
                                    .putExtra(Intent.EXTRA_SUBJECT, "PhonePigeon crash report").putExtra(Intent.EXTRA_TEXT, report), "Share crash report"))
                                CrashReporter.clear(this@MainActivity); crash = null
                            }) { Text("Share") }
                        },
                        dismissButton = { TextButton(onClick = { CrashReporter.clear(this@MainActivity); crash = null }) { Text("Dismiss") } },
                    )
                }
                val state by engine.state.collectAsStateWithLifecycle()
                var step by rememberSaveable { mutableStateOf(0) }
                val screen = if (state.paired) 3 else step
                BackHandler(enabled = screen in 1..2) { step -= 1 }
                AnimatedContent(screen, transitionSpec = {
                    (slideInHorizontally { it / 4 } + fadeIn()) togetherWith fadeOut()
                }, label = "nav") { s ->
                    when (s) {
                        0 -> WelcomeScreen { step = 1 }
                        1 -> PermissionsScreen { step = 2 }
                        2 -> PairScreen { step = 1 }
                        else -> HomeScreen(state, engine)
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        RelayEngine.get(this).refreshState()
        // After an app update Android can leave the notification listener unbound even though access is on: ask for a rebind.
        if (dev.phonepigeon.service.NotificationMirrorService.isEnabled(this) && dev.phonepigeon.service.NotificationMirrorService.instance == null) {
            runCatching {
                android.service.notification.NotificationListenerService.requestRebind(
                    android.content.ComponentName(this, dev.phonepigeon.service.NotificationMirrorService::class.java))
            }
        }
    }
}
