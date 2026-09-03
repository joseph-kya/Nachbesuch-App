package at.volkshilfe.nachbesuch.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material.icons.filled.SwipeLeft
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import at.volkshilfe.nachbesuch.ui.status.icon
import at.volkshilfe.nachbesuch.ui.status.tint

/**
 * "What do these symbols mean", ported from the iOS `StatusLegendSheet`.
 *
 * The four emoji are not self-explanatory to a volunteer on their first shift,
 * and the gesture shortcuts are otherwise undiscoverable.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StatusLegendSheet(onDismiss: () -> Unit) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.surfaceContainerLow
    ) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Text("Hilfe", style = MaterialTheme.typography.headlineSmall)

            Text(
                "Status",
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            VisitOutcome.entries.forEach { outcome ->
                Row(
                    Modifier.fillMaxWidth().clearAndSetSemantics {
                        contentDescription = outcome.germanTitle
                        stateDescription = outcome.explanation
                    },
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(outcome.emoji, style = MaterialTheme.typography.titleLarge)
                    Column(Modifier.weight(1f)) {
                        Text(outcome.germanTitle, style = MaterialTheme.typography.bodyLarge)
                        Text(
                            outcome.explanation,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Icon(outcome.icon, contentDescription = null, tint = outcome.tint, modifier = Modifier.size(20.dp))
                }
            }

            Text(
                "Gesten",
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 6.dp)
            )
            GestureRow(Icons.Default.SwipeLeft, "Nach links wischen setzt einen Schnellstatus")
            GestureRow(Icons.Default.TouchApp, "Tippen öffnet die Details")
        }
    }
}

@Composable
private fun GestureRow(icon: ImageVector, label: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
        Text(label, style = MaterialTheme.typography.bodyMedium)
    }
}
