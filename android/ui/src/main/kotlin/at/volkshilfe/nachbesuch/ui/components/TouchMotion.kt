package at.volkshilfe.nachbesuch.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer

/** Small, interruptible press response. Layer-only updates do not remeasure content.
 * Compose's animator duration scale follows the system's animation setting.
 */
@Composable
fun Modifier.touchMotion(source: MutableInteractionSource): Modifier {
    val pressed by source.collectIsPressedAsState()
    val scale = animateFloatAsState(
        targetValue = if (pressed) 0.97f else 1f,
        animationSpec = spring(dampingRatio = 1f, stiffness = 650f),
        label = "touch-pressure"
    )
    return graphicsLayer {
        scaleX = scale.value
        scaleY = scale.value
    }
}
