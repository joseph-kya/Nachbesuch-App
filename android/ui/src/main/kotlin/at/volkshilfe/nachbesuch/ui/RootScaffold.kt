package at.volkshilfe.nachbesuch.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Map
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import at.volkshilfe.nachbesuch.ui.theme.RadiusChrome

/**
 * The three-tab shell.
 *
 * A floating pill in the same chrome material as the map's control surfaces, not a
 * docked full-width Material [androidx.compose.material3.NavigationBar]. The stock
 * bar sits flush against the edge with its own drop shadow and ripple colour, which
 * previously read as a different design system from the glass panels floating over
 * the map. [Scaffold]'s `bottomBar` slot is kept — it measures whatever is placed in
 * it and reserves exactly that much space for `content`, which is the one piece of
 * plumbing not worth re-deriving by hand.
 */
@Composable
fun RootScaffold(
    map: @Composable () -> Unit,
    list: @Composable () -> Unit,
    archive: @Composable () -> Unit,
    /** Floats over the content at the top — the notice banner. */
    topOverlay: @Composable () -> Unit = {},
    /** Floats over the content just above the tab bar — the undo banner. */
    bottomOverlay: @Composable () -> Unit = {}
) {
    var selected by rememberSaveable { mutableIntStateOf(0) }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        bottomBar = { FloatingTabBar(selected = selected, onSelect = { selected = it }) }
    ) { padding ->
        // The full Scaffold padding, not just the bottom bar's — targetSdk 35 forces
        // edge-to-edge regardless of what this app asks for, so without the top inset
        // here every screen's own content (not just the map, which had enough visual
        // headroom to hide it) drew straight under the status bar clock and icons.
        Box(Modifier.fillMaxSize().padding(padding)) {
            when (selected) { 0 -> map(); 1 -> list(); else -> archive() }
            // Overlays rather than inline rows: a banner that pushes the map or the
            // list down on every appearance reflows the whole screen under the
            // user's thumb mid-tap.
            Box(Modifier.align(Alignment.TopCenter).padding(top = 8.dp)) { topOverlay() }
            Box(Modifier.align(Alignment.BottomCenter).padding(bottom = 8.dp)) { bottomOverlay() }
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
private fun FloatingTabBar(selected: Int, onSelect: (Int) -> Unit) {
    Column(
        Modifier
            .padding(horizontal = 16.dp)
            .padding(bottom = 10.dp)
            .padding(WindowInsets.navigationBars.asPaddingValues())
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .shadow(6.dp, RoundedCornerShape(RadiusChrome), clip = false)
                .background(MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.96f), RoundedCornerShape(RadiusChrome))
        ) {
            androidx.compose.foundation.layout.Row(
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
    Column(
        modifier = Modifier
            .width(84.dp)
            .clip(RoundedCornerShape(16.dp))
            .clickable(
                interactionSource = interactionSource,
                indication = ripple(),
                onClick = onClick
            )
            .padding(vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp)
    ) {
        Icon(tab.icon, contentDescription = tab.label, tint = tint, modifier = Modifier.size(24.dp))
        Text(
            tab.label,
            color = tint,
            style = MaterialTheme.typography.labelMedium.copy(
                fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal
            )
        )
    }
}
