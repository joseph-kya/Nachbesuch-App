package at.volkshilfe.nachbesuch.ui

import androidx.compose.animation.core.tween
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Map
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.Surface
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.foundation.selection.selectable
import androidx.compose.ui.semantics.Role
import at.volkshilfe.nachbesuch.ui.components.touchMotion
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import at.volkshilfe.nachbesuch.ui.theme.glossySurface
import at.volkshilfe.nachbesuch.ui.theme.RadiusChrome

/**
 * The three-tab shell.
 *
 * The tab bar is a floating pill in the same chrome material as the map's
 * control surfaces, and it genuinely floats: the screens fill the whole window
 * and draw *behind* it, exactly as the iOS tab bar does.
 *
 * It used to sit in a [androidx.compose.material3.Scaffold]'s `bottomBar` slot,
 * which reserves its height and shrinks the content. That left a dead band of
 * flat background under every screen, and because the pill has rounded corners,
 * that band showed through around them as black notches — the bar read as
 * pasted onto the app rather than hovering over it. Each screen now receives
 * the bar's measured height as content padding instead, so lists scroll all the
 * way under it and nothing is ever clipped behind it.
 */
@Composable
fun RootScaffold(
    map: @Composable (PaddingValues) -> Unit,
    list: @Composable (PaddingValues) -> Unit,
    archive: @Composable (PaddingValues) -> Unit,
    /** Floats over the content at the top — the notice banner. */
    topOverlay: @Composable () -> Unit = {}
) {
    var selected by rememberSaveable { mutableIntStateOf(0) }
    var barHeight by remember { mutableStateOf(0.dp) }
    val tabState = rememberSaveableStateHolder()
    val density = LocalDensity.current
    val statusBar = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()

    // A Surface, not a bare Box with a background colour. Surface is what
    // publishes LocalContentColor, and dropping the Scaffold dropped it: every
    // Text that did not name a colour of its own fell back to the default black,
    // which in dark mode meant invisible headlines.
    Surface(
        modifier = Modifier.fillMaxSize(),
        color = MaterialTheme.colorScheme.background,
        contentColor = MaterialTheme.colorScheme.onBackground
    ) {
    Box(Modifier.fillMaxSize()) {
        // The map is deliberately full-bleed: its tiles run under the status bar
        // the way they do on iOS, and it insets its own chrome instead.
        val mapPadding = PaddingValues(top = statusBar, bottom = barHeight)
        val listPadding = PaddingValues(top = statusBar, bottom = barHeight)

        // Preserve scroll/search state without keeping an inactive map rendering.
        tabState.SaveableStateProvider(selected) {
            when (selected) {
                0 -> map(mapPadding)
                1 -> list(listPadding)
                else -> archive(listPadding)
            }
        }

        // An overlay rather than an inline row: a banner that pushes the map or
        // the list down on every appearance reflows the whole screen under the
        // user's thumb mid-tap. Notices are app-wide because a failed write can
        // come from any screen; the undo banner is not, and lives in the list.
        Box(Modifier.align(Alignment.TopCenter).padding(top = statusBar + 8.dp)) { topOverlay() }

        FloatingTabBar(
            selected = selected,
            onSelect = { selected = it },
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .onSizeChanged { barHeight = with(density) { it.height.toDp() } }
        )
    }
    }
}

private data class TabSpec(val label: String, val icon: androidx.compose.ui.graphics.vector.ImageVector)

private val Tabs = listOf(
    TabSpec("Karte", Icons.Default.Map),
    TabSpec("Liste", Icons.AutoMirrored.Filled.List),
    TabSpec("Archiv", Icons.Default.Archive),
)

@Composable
private fun FloatingTabBar(selected: Int, onSelect: (Int) -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier
            .padding(horizontal = 16.dp)
            .padding(bottom = 10.dp)
            .padding(WindowInsets.navigationBars.asPaddingValues())
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .glossySurface(RoundedCornerShape(RadiusChrome), elevation = 6.dp)
        ) {
            Row(
                Modifier.fillMaxWidth().padding(vertical = 8.dp),
                horizontalArrangement = Arrangement.SpaceEvenly
            ) {
                Tabs.forEachIndexed { index, tab ->
                    TabItem(tab, isSelected = selected == index, onClick = { onSelect(index) })
                }
            }
        }
    }
}

@Composable
private fun TabItem(tab: TabSpec, isSelected: Boolean, onClick: () -> Unit) {
    val tint: Color by animateColorAsState(
        if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
        label = "tab-tint"
    )
    val interactionSource = remember { MutableInteractionSource() }
    val haptics = LocalHapticFeedback.current
    val selectionFill by animateColorAsState(
        if (isSelected) MaterialTheme.colorScheme.primary.copy(alpha = 0.12f) else Color.Transparent,
        animationSpec = tween(180), label = "tab-selection"
    )
    Column(
        modifier = Modifier
            .width(84.dp)
            .touchMotion(interactionSource)
            .clip(RoundedCornerShape(16.dp))
            .background(selectionFill)
            .selectable(
                selected = isSelected,
                role = Role.Tab,
                interactionSource = interactionSource,
                indication = ripple(),
                onClick = {
                    if (!isSelected) {
                        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        onClick()
                    }
                }
            )
            .padding(vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp)
    ) {
        Icon(tab.icon, contentDescription = null, tint = tint, modifier = Modifier.size(24.dp))
        Text(
            tab.label,
            color = tint,
            style = MaterialTheme.typography.labelMedium.copy(
                fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal
            )
        )
    }
}
