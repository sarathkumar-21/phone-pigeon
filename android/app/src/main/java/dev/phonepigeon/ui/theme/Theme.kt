package dev.phonepigeon.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Surface
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

object Brand {
    val Violet = Color(0xFF6B5BF9)
    val Blue = Color(0xFF3B8CFF)
    val Cyan = Color(0xFF36D1DC)
    val Coral = Color(0xFFFF5B3A)
    val Green = Color(0xFF22C55E)
    val gradient = Brush.linearGradient(listOf(Violet, Blue, Cyan))
    val gradientSoft = Brush.linearGradient(listOf(Violet, Blue))

    fun hex(s: String): Color = runCatching { Color(android.graphics.Color.parseColor(s)) }.getOrDefault(Blue)
}

private val Dark = darkColorScheme(
    primary = Brand.Violet,
    onPrimary = Color.White,
    secondary = Brand.Blue,
    tertiary = Brand.Cyan,
    background = Color(0xFF0E0D1A),
    surface = Color(0xFF0E0D1A),
    surfaceContainer = Color(0xFF181727),
    surfaceContainerHigh = Color(0xFF211F33),
    surfaceContainerHighest = Color(0xFF2A2840),
    onBackground = Color(0xFFF1F0FA),
    onSurface = Color(0xFFF1F0FA),
    onSurfaceVariant = Color(0xFFA9A6C2),
    outlineVariant = Color(0x22FFFFFF),
    error = Color(0xFFFF6B6B),
)

private val Light = lightColorScheme(
    primary = Brand.Violet,
    onPrimary = Color.White,
    secondary = Brand.Blue,
    tertiary = Brand.Cyan,
    background = Color(0xFFF6F5FC),
    surface = Color(0xFFF6F5FC),
    surfaceContainer = Color(0xFFFFFFFF),
    surfaceContainerHigh = Color(0xFFF0EEFA),
    surfaceContainerHighest = Color(0xFFE7E4F6),
    onBackground = Color(0xFF16142A),
    onSurface = Color(0xFF16142A),
    onSurfaceVariant = Color(0xFF6A6787),
    outlineVariant = Color(0x14000000),
)

private val Rounded = FontFamily.SansSerif

private val AppTypography = Typography(
    displaySmall = TextStyle(fontFamily = Rounded, fontWeight = FontWeight.Bold, fontSize = 34.sp, lineHeight = 40.sp, letterSpacing = (-0.5).sp),
    headlineMedium = TextStyle(fontFamily = Rounded, fontWeight = FontWeight.Bold, fontSize = 26.sp, lineHeight = 32.sp, letterSpacing = (-0.3).sp),
    headlineSmall = TextStyle(fontFamily = Rounded, fontWeight = FontWeight.SemiBold, fontSize = 22.sp, lineHeight = 28.sp),
    titleLarge = TextStyle(fontFamily = Rounded, fontWeight = FontWeight.SemiBold, fontSize = 19.sp, lineHeight = 24.sp),
    titleMedium = TextStyle(fontFamily = Rounded, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, lineHeight = 22.sp),
    bodyLarge = TextStyle(fontSize = 16.sp, lineHeight = 23.sp),
    bodyMedium = TextStyle(fontSize = 14.sp, lineHeight = 20.sp),
    labelLarge = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 15.sp),
    labelMedium = TextStyle(fontWeight = FontWeight.Medium, fontSize = 12.sp, letterSpacing = 0.2.sp),
)

@Composable
fun PhonePigeonTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) Dark else Light,
        typography = AppTypography,
        shapes = Shapes(
            small = RoundedCornerShape(12.dp),
            medium = RoundedCornerShape(18.dp),
            large = RoundedCornerShape(26.dp),
        ),
    ) {
        // Without a Surface, Compose's default text colour is black, unreadable on the dark theme's dark background.
        Surface(color = MaterialTheme.colorScheme.background, contentColor = MaterialTheme.colorScheme.onBackground, content = content)
    }
}
