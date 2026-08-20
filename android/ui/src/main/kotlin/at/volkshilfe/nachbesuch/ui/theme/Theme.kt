package at.volkshilfe.nachbesuch.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

val VolkshilfeRed = Color(0xFFFF3B45)
val GlassLight = Color(0xF2FFFFFF)
val GlassDark = Color(0xE81C1C1E)

val RadiusSmall = 12.dp
val RadiusControl = 16.dp
val RadiusRow = 22.dp
val RadiusCard = 28.dp
val RadiusChrome = 28.dp

private val LightColors = lightColorScheme(
    primary = VolkshilfeRed,
    background = Color(0xFFF5F5F7),
    surface = Color.White,
    onPrimary = Color.White
)

private val DarkColors = darkColorScheme(
    primary = VolkshilfeRed,
    background = Color(0xFF000000),
    surface = Color(0xFF1C1C1E),
    onPrimary = Color.White
)

@Composable
fun NachbesuchTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) DarkColors else LightColors, content = content)
}
