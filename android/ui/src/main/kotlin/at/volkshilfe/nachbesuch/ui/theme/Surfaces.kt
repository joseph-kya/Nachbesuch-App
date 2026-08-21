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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

@Composable
fun GlassCard(
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = PaddingValues(16.dp),
    content: @Composable ColumnScope.() -> Unit
) {
    androidx.compose.foundation.layout.Column(
        modifier = modifier
            .shadow(8.dp, RoundedCornerShape(RadiusCard), clip = false)
            .background(MaterialTheme.colorScheme.surfaceContainerHigh, RoundedCornerShape(RadiusCard))
            .border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(RadiusCard))
            .padding(contentPadding),
        content = content
    )
}

@Composable
fun GlassRow(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    androidx.compose.foundation.layout.Column(
        modifier = modifier
            .background(MaterialTheme.colorScheme.surfaceContainerHigh, RoundedCornerShape(RadiusRow))
            .border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(RadiusRow))
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
            .shadow(6.dp, RoundedCornerShape(cornerRadius), clip = false)
            .background(MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.94f), RoundedCornerShape(cornerRadius))
            .border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(cornerRadius))
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
    size: Dp = 46.dp,
    content: @Composable () -> Unit
) {
    val interactionSource = remember { MutableInteractionSource() }
    Box(
        modifier = modifier
            .size(size)
            .shadow(4.dp, CircleShape, clip = false)
            .background(tint, CircleShape)
            .border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, CircleShape)
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
