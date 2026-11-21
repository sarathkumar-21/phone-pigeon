package dev.phonepigeon.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.ui.Alignment
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.PhoneAndroid
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.phonepigeon.pair.NearbyPairing
import dev.phonepigeon.ui.theme.Brand

/**
 * Pairing is "nearby" only: while this screen is open the phone is visible to PhonePigeon on the same Wi-Fi, and the
 * Mac picks it from its Add Phone list. Both screens then show a six-digit code that must be confirmed on each.
 */
@Composable
fun PairScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    DisposableEffect(Unit) {
        NearbyPairing.start(context)
        onDispose { NearbyPairing.stop() }
    }
    val nearby by NearbyPairing.state.collectAsStateWithLifecycle()

    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF0E1020), Color(0xFF16183A))))) {
        Radar(Modifier.align(Alignment.Center))

        Row(Modifier.statusBarsPadding().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back", tint = Color.White) }
            Text("Pair with your Mac", color = Color.White, style = MaterialTheme.typography.titleLarge)
        }

        Surface(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding().padding(16.dp),
            shape = RoundedCornerShape(26.dp),
            color = MaterialTheme.colorScheme.surfaceContainer.copy(alpha = 0.96f),
        ) {
            Column(Modifier.padding(20.dp)) {
                when (nearby) {
                    is NearbyPairing.State.Finishing -> Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.5.dp)
                        Spacer(Modifier.width(14.dp))
                        Column {
                            Text("Pairing securely…", style = MaterialTheme.typography.titleMedium)
                            Text("Exchanging keys with your Mac", style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    else -> {
                        Text("Waiting for your Mac", style = MaterialTheme.typography.titleLarge)
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "On your Mac, open PhonePigeon, choose File › Add Phone and pick this phone from the list. " +
                                "Both devices need to be on the same Wi-Fi.",
                            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                Spacer(Modifier.height(14.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Rounded.Lock, null, tint = Brand.Green, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Visible only while this screen is open · end-to-end encrypted",
                        style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }

    when (val n = nearby) {
        is NearbyPairing.State.Confirm -> AlertDialog(
            onDismissRequest = { NearbyPairing.decide(false) },
            title = { Text("Pair with ${n.macName}?") },
            text = {
                Column {
                    Text("Check that this code is the same on your Mac. If it is different, or you didn't start pairing on your Mac, tap Cancel.")
                    Spacer(Modifier.height(14.dp))
                    Text(n.code, style = MaterialTheme.typography.displaySmall, fontFamily = FontFamily.Monospace,
                        textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
                }
            },
            confirmButton = { TextButton(onClick = { NearbyPairing.decide(true) }) { Text("Codes match") } },
            dismissButton = { TextButton(onClick = { NearbyPairing.decide(false) }) { Text("Cancel") } },
        )
        is NearbyPairing.State.Failed -> AlertDialog(
            onDismissRequest = { NearbyPairing.dismissFailure() },
            title = { Text("Pairing didn't finish") },
            text = { Text(n.message) },
            confirmButton = { TextButton(onClick = { NearbyPairing.dismissFailure() }) { Text("OK") } },
        )
        else -> {}
    }
}

/** Slow expanding rings around a phone icon: "I'm visible, waiting for the Mac". */
@Composable
private fun Radar(modifier: Modifier = Modifier) {
    val t = rememberInfiniteTransition(label = "radar")
    val p by t.animateFloat(0f, 1f, infiniteRepeatable(tween(2800, easing = LinearEasing), RepeatMode.Restart), label = "p")
    Box(modifier.size(300.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            for (i in 0..2) {
                val phase = (p + i / 3f) % 1f
                drawCircle(Brand.Cyan.copy(alpha = (1f - phase) * 0.35f), radius = size.minDimension / 2 * (0.3f + 0.7f * phase),
                    style = androidx.compose.ui.graphics.drawscope.Stroke(width = 3f))
            }
        }
        Box(Modifier.size(84.dp).background(Brush.linearGradient(listOf(Brand.Violet, Brand.Cyan)), RoundedCornerShape(24.dp)),
            contentAlignment = Alignment.Center) {
            Icon(Icons.Rounded.PhoneAndroid, null, tint = Color.White, modifier = Modifier.size(44.dp))
        }
    }
}
