package at.volkshilfe.nachbesuch.feature.shared

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import at.volkshilfe.nachbesuch.domain.list.HouseListBuilder
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.ui.components.MinTouchTarget
import at.volkshilfe.nachbesuch.ui.components.OutcomeGlyph
import at.volkshilfe.nachbesuch.ui.status.displayTitle
import at.volkshilfe.nachbesuch.ui.theme.RadiusControl

/**
 * Shown when several pins are drawn on top of one another, so a tap cannot pick
 * between them — otherwise whichever marker happened to be on top would always
 * win, and the houses underneath would be permanently unreachable.
 *
 * Ported from the iOS `StackedPinsSheet`. Android had no equivalent: the OSM
 * import happily produces two houses a few metres apart (for example
 * "Kleeblattgasse 4" and "Kleeblattgasse 4, 1010 Wien"), whose pins coincide at
 * every usable zoom. Tapping one of those, recording a status and watching the
 * pin apparently not change was this gap — the status landed on the house
 * underneath, whose updated pin stayed hidden behind the one on top.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StackedPinsSheet(
    houses: List<House>,
    scope: DayScope,
    onSelect: (String) -> Unit,
    onDismiss: () -> Unit
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.surfaceContainerLow
    ) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Pins an dieser Stelle", style = MaterialTheme.typography.headlineSmall)
                    Text(
                        "${houses.size} Häuser liegen hier übereinander.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                TextButton(onClick = onDismiss) { Text("Fertig") }
            }

            LazyColumn(
                Modifier.heightIn(max = 420.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                items(houses, key = { it.id }) { house ->
                    val outcome = HouseListBuilder.rows(listOf(house), scope).first().markerOutcome
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(RadiusControl))
                            .background(
                                MaterialTheme.colorScheme.surfaceContainerHigh,
                                RoundedCornerShape(RadiusControl)
                            )
                            .clickable { onSelect(house.id) }
                            .heightIn(min = MinTouchTarget)
                            .padding(horizontal = 14.dp, vertical = 10.dp)
                            .clearAndSetSemantics {
                                contentDescription = house.address
                                stateDescription = outcome.displayTitle
                            },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        OutcomeGlyph(outcome, size = 22.dp)
                        Column(Modifier.weight(1f)) {
                            Text(
                                house.address,
                                style = MaterialTheme.typography.bodyLarge,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            Text(
                                outcome.displayTitle,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Icon(
                            Icons.AutoMirrored.Filled.KeyboardArrowRight,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(18.dp)
                        )
                    }
                }
            }
        }
    }
}
