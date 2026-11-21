package dev.phonepigeon.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.SimCard
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.phonepigeon.proto.SimCard
import dev.phonepigeon.service.Connection
import dev.phonepigeon.ui.theme.Brand
import kotlin.math.cos
import kotlin.math.sin

@Composable
fun Card(modifier: Modifier = Modifier, padding: Dp = 18.dp, content: @Composable ColumnScope.() -> Unit) {
    Surface(
        modifier = modifier,
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surfaceContainer,
        tonalElevation = 0.dp,
        shadowElevation = 0.dp,
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
    ) { Column(Modifier.padding(padding), content = content) }
}

@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier) {
    Text(text.uppercase(), modifier = modifier.padding(start = 4.dp, bottom = 10.dp, top = 6.dp),
        style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, letterSpacing = 1.2.sp)
}

@Composable
fun IconBadge(icon: ImageVector, tint: Color, size: Dp = 40.dp) {
    Box(
        Modifier.size(size).clip(RoundedCornerShape(size * 0.3f))
            .background(Brush.linearGradient(listOf(tint, tint.copy(alpha = 0.72f)))),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, null, tint = Color.White, modifier = Modifier.size(size * 0.5f)) }
}

/** Slowly drifting colour blobs — the same backdrop as the Mac onboarding. */
@Composable
fun AuroraBackground(modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    val t by rememberInfiniteTransition(label = "aurora").animateFloat(
        0f, (2 * Math.PI).toFloat(), infiniteRepeatable(tween(18_000, easing = LinearEasing)), label = "t")
    Box(modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        Canvas(Modifier.fillMaxSize().blur(90.dp).alpha(0.55f)) {
            val blobs = listOf(Brand.Violet to Offset(0.2f, 0.18f), Brand.Blue to Offset(0.85f, 0.3f),
                Brand.Cyan to Offset(0.6f, 0.85f), Brand.Coral to Offset(0.1f, 0.75f))
            blobs.forEachIndexed { i, (c, o) ->
                val x = size.width * (o.x + 0.1f * sin(t + i))
                val y = size.height * (o.y + 0.08f * cos(t * 1.3f + i))
                drawCircle(c.copy(alpha = 0.55f), radius = size.minDimension * 0.42f, center = Offset(x, y))
            }
        }
        content()
    }
}

@Composable
fun StatusPill(connection: Connection) {
    val color = when (connection) {
        Connection.LAN -> Brand.Green
        Connection.CLOUD -> Brand.Blue
        Connection.CONNECTING -> Color(0xFFF59E0B)
        Connection.OFFLINE -> Color(0xFFEF4444)
    }
    val pulse by rememberInfiniteTransition(label = "pulse").animateFloat(0.7f, 1.8f,
        infiniteRepeatable(tween(1600), RepeatMode.Restart), label = "p")
    Row(
        Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.18f)).padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(contentAlignment = Alignment.Center) {
            Box(Modifier.size(9.dp).scale(pulse).alpha((1.8f - pulse) / 1.1f).clip(CircleShape).background(color.copy(alpha = 0.6f)))
            Box(Modifier.size(7.dp).clip(CircleShape).background(color).border(1.dp, Color.White.copy(alpha = 0.6f), CircleShape))
        }
        Spacer(Modifier.width(7.dp))
        Text(connection.label, color = Color.White, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
    }
}

/** Credit-card style SIM tile, matching the Mac's SimCardTile. */
@Composable
fun SimTile(sim: SimCard, modifier: Modifier = Modifier) {
    val c = Brand.hex(sim.accentColorHex)
    Box(
        modifier.clip(RoundedCornerShape(22.dp))
            .background(Brush.linearGradient(listOf(c, c.copy(alpha = 0.65f).compositeOver(Color.Black))))
            .padding(18.dp),
    ) {
        Canvas(Modifier.matchParentSize()) {
            drawCircle(Color.White.copy(alpha = 0.10f), radius = size.width * 0.45f, center = Offset(size.width * 1.0f, 0f))
            drawCircle(Color.White.copy(alpha = 0.06f), radius = size.width * 0.32f, center = Offset(size.width * 1.05f, size.height))
        }
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.SimCard, null, tint = Color.White, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("SIM ${sim.slotIndex + 1}", color = Color.White, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.labelLarge)
            }
            Spacer(Modifier.height(22.dp))
            Text(sim.carrierName, color = Color.White, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
            Text(sim.phoneNumber.ifBlank { "Number hidden by carrier" }, color = Color.White.copy(alpha = 0.85f),
                fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodyMedium)
            Spacer(Modifier.height(14.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(sim.displayName, color = Color.White, style = MaterialTheme.typography.labelMedium, modifier = Modifier.weight(1f, fill = false))
                Spacer(Modifier.weight(1f))
                if (sim.isDefaultSms) Tag("SMS")
                if (sim.isDefaultVoice) Tag("Calls")
            }
        }
    }
}

@Composable
private fun Tag(s: String) {
    Text("Default $s", color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.Bold,
        modifier = Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.22f)).padding(horizontal = 7.dp, vertical = 2.dp))
}

private fun Color.compositeOver(bg: Color): Color {
    val a = alpha
    return Color(red * a + bg.red * (1 - a), green * a + bg.green * (1 - a), blue * a + bg.blue * (1 - a), 1f)
}

@Composable
fun GradientButton(text: String, icon: ImageVector? = null, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        enabled = enabled,
        shape = RoundedCornerShape(18.dp),
        color = Color.Transparent,
        modifier = modifier.height(56.dp).alpha(if (enabled) 1f else 0.5f),
    ) {
        Box(Modifier.fillMaxSize().background(Brand.gradientSoft), contentAlignment = Alignment.Center) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (icon != null) { Icon(icon, null, tint = Color.White); Spacer(Modifier.width(8.dp)) }
                Text(text, color = Color.White, style = MaterialTheme.typography.labelLarge)
            }
        }
    }
}
