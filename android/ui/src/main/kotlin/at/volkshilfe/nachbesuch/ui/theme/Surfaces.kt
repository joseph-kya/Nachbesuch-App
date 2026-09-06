package at.volkshilfe.nachbesuch.ui.theme

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.clip
import at.volkshilfe.nachbesuch.ui.components.touchMotion
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Gloss comes from a fixed light gradient and rim, without live backdrop blur.
 * Mostly opaque surfaces keep map labels from competing with control text.
 */
@Composable
fun Modifier.glossySurface(
    shape: Shape,
    base: Color = MaterialTheme.colorScheme.surfaceContainerHigh,
    elevation: Dp = 0.dp
): Modifier {
    val dark = MaterialTheme.colorScheme.background.red < 0.5f
    val face = Brush.verticalGradient(listOf(
        lerp(base, Color.White, if (dark) 0.07f else 0.55f),
        base.copy(alpha = 0.97f),
        lerp(base, MaterialTheme.colorScheme.primary, if (dark) 0.025f else 0.015f)
    ))
    val rim = Brush.linearGradient(listOf(
        Color.White.copy(alpha = if (dark) 0.26f else 0.95f),
        MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f),
        Color.White.copy(alpha = if (dark) 0.06f else 0.5f)
    ))
    return shadow(elevation, shape, clip = false)
        .background(face, shape)
        .border(0.75.dp, rim, shape)
}

@Composable
fun GlassCard(
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = PaddingValues(16.dp),
    content: @Composable ColumnScope.() -> Unit
) {
    androidx.compose.foundation.layout.Column(
        modifier = modifier
            .glossySurface(RoundedCornerShape(RadiusCard), elevation = 4.dp)
            .padding(contentPadding),
        content = content
    )
}

@Composable
fun GlassRow(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    androidx.compose.foundation.layout.Column(
        modifier = modifier
            .glossySurface(RoundedCornerShape(RadiusRow))
            .padding(16.dp),
        content = content
    )
}

/**
 * A floating chrome panel — the map's control surfaces (top summary, bottom action
 * bar, route cards). One shape shared across every one of them so the map reads as
 * one consistent navigation layer, the way `.navigationGlass` does on iOS.
 */
@Composable
fun ChromePanel(
    modifier: Modifier = Modifier,
    cornerRadius: Dp = RadiusChrome,
    contentPadding: PaddingValues = PaddingValues(0.dp),
    content: @Composable ColumnScope.() -> Unit
) {
    androidx.compose.foundation.layout.Column(
        modifier = modifier
            .glossySurface(RoundedCornerShape(cornerRadius), elevation = 6.dp)
            .padding(contentPadding),
        content = content
    )
}

/**
 * A compact circular chrome button — the map's "..." / layers / locate controls.
 *
 * The stock [androidx.compose.material3.FloatingActionButton] is a 56dp Material
 * surface with its own heavy elevation shadow and a rounded-square default shape; a
 * row of them next to a [ChromePanel] read as two different design systems on one
 * screen. This is the same panel material at button size, so every floating control
 * on the map is visually one family.
 */
@Composable
fun ChromeIconButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tint: Color = MaterialTheme.colorScheme.surfaceContainerHigh,
    size: Dp = 48.dp,
    content: @Composable () -> Unit
) {
    val interactionSource = remember { MutableInteractionSource() }
    Box(
        modifier = modifier
            .size(size)
            .touchMotion(interactionSource)
            .glossySurface(CircleShape, base = tint, elevation = 4.dp)
            .clip(CircleShape)
            .clickable(
                interactionSource = interactionSource,
                indication = ripple(bounded = true, radius = size / 2),
                onClick = onClick
            ),
        contentAlignment = Alignment.Center
    ) {
        content()
    }
}
