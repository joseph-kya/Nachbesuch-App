package at.volkshilfe.nachbesuch.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

val VolkshilfeRed = Color(0xFFE0303F)

/**
 * One rounded-corner family for everything: dialogs, menus, buttons, text
 * fields, chips and sheets all read as the same design language instead of a
 * mix of Material's 4 dp squares and ad-hoc radii.
 */
private val AppShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(12.dp),
    medium = RoundedCornerShape(16.dp),
    large = RoundedCornerShape(20.dp),
    extraLarge = RoundedCornerShape(28.dp)
)

val RadiusSmall = 12.dp
val RadiusControl = 16.dp
val RadiusRow = 22.dp
val RadiusCard = 28.dp
val RadiusChrome = 28.dp

/**
 * A full, deliberate colour scheme, not a four-token override.
 *
 * [lightColorScheme]/[darkColorScheme] fill in every token you don't pass with
 * Material's baseline palette — which is violet. Overriding only primary/background/
 * surface/onPrimary (the previous shape of this file) left every derived surface —
 * chips, the nav bar, `surfaceContainerHigh` — tinted lavender regardless of the red
 * accent, because [FilterChip], [Surface] and the stock [NavigationBar] all read
 * those derived tokens, not primary. Every neutral tone below is genuinely neutral.
 */
private val LightColors = lightColorScheme(
    primary = VolkshilfeRed,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFFFDAD9),
    onPrimaryContainer = Color(0xFF410004),
    secondary = Color(0xFF5B5F62),
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFEBEEF0),
    onSecondaryContainer = Color(0xFF1A1C1E),
    tertiary = Color(0xFF147EFB),
    onTertiary = Color.White,
    background = Color(0xFFF5F5F7),
    onBackground = Color(0xFF1A1C1E),
    surface = Color(0xFFF5F5F7),
    onSurface = Color(0xFF1A1C1E),
    surfaceVariant = Color(0xFFE6E6E9),
    onSurfaceVariant = Color(0xFF5B5F62),
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFF9F9FA),
    surfaceContainer = Color(0xFFF1F1F3),
    surfaceContainerHigh = Color(0xFFFFFFFF),
    surfaceContainerHighest = Color(0xFFEBEBED),
    outline = Color(0xFFC4C6C8),
    outlineVariant = Color(0xFFE1E2E4),
    error = Color(0xFFBA1A1A),
    onError = Color.White,
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFFFF6961),
    onPrimary = Color(0xFF680007),
    primaryContainer = Color(0xFF930010),
    onPrimaryContainer = Color(0xFFFFDAD9),
    secondary = Color(0xFFC4C6C8),
    onSecondary = Color(0xFF2C2F31),
    secondaryContainer = Color(0xFF3A3D40),
    onSecondaryContainer = Color(0xFFE0E2E4),
    tertiary = Color(0xFF7DB4FF),
    onTertiary = Color(0xFF00325A),
    background = Color(0xFF0B0B0C),
    onBackground = Color(0xFFE4E3E4),
    surface = Color(0xFF0B0B0C),
    onSurface = Color(0xFFE4E3E4),
    surfaceVariant = Color(0xFF2C2D2F),
    onSurfaceVariant = Color(0xFFC4C6C8),
    surfaceContainerLowest = Color(0xFF060606),
    surfaceContainerLow = Color(0xFF141415),
    surfaceContainer = Color(0xFF1C1C1E),
    surfaceContainerHigh = Color(0xFF232326),
    surfaceContainerHighest = Color(0xFF2E2E31),
    outline = Color(0xFF54565A),
    outlineVariant = Color(0xFF3A3B3E),
    error = Color(0xFFFFB4AB),
    onError = Color(0xFF690005),
)

/**
 * A tighter, heavier-weight type ramp than Material's default (Roboto, light
 * headlines). iOS uses San Francisco's bold, condensed headline weights; there is no
 * equivalent system font here, so the same visual effect — headlines read as
 * confident, not as placeholder text — comes from weight and tracking instead of a
 * different typeface.
 */
val AppTypography = Typography().let { base ->
    base.copy(
        displayLarge = base.displayLarge.copy(fontWeight = FontWeight.Bold),
        headlineLarge = base.headlineLarge.copy(fontWeight = FontWeight.Bold, letterSpacing = (-0.3).sp),
        headlineMedium = base.headlineMedium.copy(fontWeight = FontWeight.Bold, letterSpacing = (-0.2).sp),
        headlineSmall = base.headlineSmall.copy(fontWeight = FontWeight.SemiBold),
        titleLarge = base.titleLarge.copy(fontWeight = FontWeight.SemiBold),
        titleMedium = base.titleMedium.copy(fontWeight = FontWeight.SemiBold),
        titleSmall = base.titleSmall.copy(fontWeight = FontWeight.SemiBold),
        labelLarge = base.labelLarge.copy(fontWeight = FontWeight.SemiBold),
        bodyLarge = base.bodyLarge.copy(letterSpacing = 0.1.sp),
    )
}

/**
 * Applies the chosen [AppAccent] over a finished neutral scheme.
 *
 * Only the accent-derived tokens are replaced. The neutral surface/outline ramp
 * above stays exactly as authored, which is the whole point of defining it by
 * hand: re-deriving a scheme from a seed colour would drag Material's tonal
 * tinting back into every container and undo `e8a5c73`.
 */
private fun ColorScheme.withAccent(accent: AppAccent, dark: Boolean): ColorScheme = copy(
    primary = if (dark) accent.dark else accent.light,
    primaryContainer = if (dark) accent.darkContainer else accent.lightContainer,
    // The container tones are chosen so the on-colour flips with the scheme.
    onPrimary = if (dark) Color(0xFF3A0004) else Color.White,
    onPrimaryContainer = if (dark) accent.lightContainer else Color(0xFF2A0004),
)

@Composable
fun NachbesuchTheme(
    appearance: AppAppearance = AppAppearance.SYSTEM,
    accent: AppAccent = AppAccent.VOLKSHILFE,
    content: @Composable () -> Unit
) {
    val dark = when (appearance) {
        AppAppearance.SYSTEM -> isSystemInDarkTheme()
        AppAppearance.LIGHT -> false
        AppAppearance.DARK -> true
    }
    MaterialTheme(
        colorScheme = (if (dark) DarkColors else LightColors).withAccent(accent, dark),
        typography = AppTypography,
        shapes = AppShapes,
        content = content,
    )
}
