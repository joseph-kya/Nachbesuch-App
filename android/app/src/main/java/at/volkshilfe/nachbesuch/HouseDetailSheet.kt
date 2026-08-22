package at.volkshilfe.nachbesuch

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import at.volkshilfe.nachbesuch.ui.theme.GlassRow

@OptIn(ExperimentalMaterial3Api::class, androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
fun HouseDetailSheet(
    house: House,
    scope: DayScope,
    onScopeChange: (DayScope) -> Unit,
    onOutcome: (String, VisitOutcome?) -> Unit,
    onFillOpenDoors: (VisitOutcome?) -> Unit,
    onRenameUnit: (String, String) -> Unit,
    onResize: (Int) -> Unit,
    onDelete: () -> Unit,
    onDismiss: () -> Unit
) {
    var countText by remember(house.id, house.units.size) { mutableStateOf(house.units.size.toString()) }
    var renameTarget by remember { mutableStateOf<String?>(null) }
    val openDoorCount = house.units.count { it.isOpen(scope) }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        LazyColumn(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            item {
                Text(house.address, style = MaterialTheme.typography.headlineSmall)
                Text(
                    if (house.isDamaged) "Daten beschädigt – Änderungen sind gesperrt" else "Türstatus",
                    color = if (house.isDamaged) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(DayScope.COMBINED to "Gesamt", DayScope.DAY_1 to "Tag 1", DayScope.DAY_2 to "Tag 2")
                        .forEach { (candidate, label) ->
                            FilterChip(
                                selected = scope == candidate,
                                onClick = { onScopeChange(candidate) },
                                label = { Text(label) }
                            )
                        }
                }
            }
            // Bulk action: mark every still-open door in the visible scope at once.
            if (!house.isDamaged && openDoorCount > 0 && scope != DayScope.COMBINED) {
                item {
                    GlassRow {
                        Row(
                            Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text("Alle offenen Türen", style = MaterialTheme.typography.titleMedium)
                                Text(
                                    "$openDoorCount Türen in ${if (scope == DayScope.DAY_1) "Tag 1" else "Tag 2"} auf einen Status setzen",
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    style = MaterialTheme.typography.bodySmall
                                )
                            }
                        }
                        HorizontalDivider(Modifier.padding(vertical = 8.dp))
                        androidx.compose.foundation.layout.FlowRow(
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            VisitOutcome.entries.forEach { outcome ->
                                FilterChip(
                                    selected = false,
                                    onClick = { onFillOpenDoors(outcome) },
                                    label = { Text("${outcome.emoji} ${outcome.shortTitle}") }
                                )
                            }
                        }
                    }
                }
            }
            if (house.isApartmentBuilding) {
                item {
                    GlassRow {
                        Text("Mehrparteienhaus · ${house.units.size} Türen", style = MaterialTheme.typography.titleMedium)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedTextField(
                                value = countText,
                                onValueChange = { countText = it.filter(Char::isDigit).take(3) },
                                label = { Text("Anzahl") },
                                singleLine = true,
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                modifier = Modifier.weight(1f)
                            )
                            Button(
                                onClick = { countText.toIntOrNull()?.let(onResize) },
                                enabled = !house.isDamaged
                            ) { Text("Ändern") }
                        }
                    }
                }
            } else {
                item {
                    TextButton(
                        onClick = { onResize(2) },
                        enabled = !house.isDamaged
                    ) { Text("Als Mehrparteienhaus markieren") }
                }
            }
            items(house.units, key = { it.id }) { door ->
                GlassRow {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(door.label, style = MaterialTheme.typography.titleMedium)
                                Text(
                                    door.displayOutcome(scope)?.germanTitle ?: "Noch offen",
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            IconButton(onClick = { renameTarget = door.id }, enabled = !house.isDamaged) {
                                Icon(Icons.Default.Edit, contentDescription = "${door.label} umbenennen")
                            }
                        }
                        Text(door.displayOutcome(scope)?.emoji ?: "○", style = MaterialTheme.typography.headlineSmall)
                    }
                    HorizontalDivider(Modifier.padding(vertical = 8.dp))
                    // Labelled chips instead of bare emoji buttons: the current
                    // state is highlighted, every option says what it does.
                    androidx.compose.foundation.layout.FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        val current = door.displayOutcome(scope)
                        VisitOutcome.entries.forEach { outcome ->
                            FilterChip(
                                selected = current == outcome,
                                onClick = { onOutcome(door.id, outcome) },
                                enabled = !house.isDamaged,
                                label = { Text("${outcome.emoji} ${outcome.shortTitle}") }
                            )
                        }
                        FilterChip(
                            selected = current == null,
                            onClick = { onOutcome(door.id, null) },
                            enabled = !house.isDamaged,
                            label = { Text("○ Offen") }
                        )
                    }
                }
            }
            item {
                TextButton(onClick = onDelete) {
                    Text("Haus löschen", color = MaterialTheme.colorScheme.error)
                }
            }
            item { androidx.compose.foundation.layout.Spacer(Modifier.padding(bottom = 20.dp)) }
        }
    }

    renameTarget?.let { unitID ->
        val door = house.units.firstOrNull { it.id == unitID }
        RenameDoorDialog(
            currentLabel = door?.label.orEmpty(),
            onConfirm = { label ->
                onRenameUnit(unitID, label)
                renameTarget = null
            },
            onDismiss = { renameTarget = null }
        )
    }
}

@Composable
private fun RenameDoorDialog(currentLabel: String, onConfirm: (String) -> Unit, onDismiss: () -> Unit) {
    var label by rememberSaveable { mutableStateOf(currentLabel) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Tür umbenennen") },
        text = {
            OutlinedTextField(
                value = label,
                onValueChange = { label = it.take(40) },
                singleLine = true,
                label = { Text("Bezeichnung") }
            )
        },
        confirmButton = {
            Button(onClick = { onConfirm(label) }, enabled = label.trim().isNotEmpty()) { Text("Speichern") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Abbrechen") } }
    )
}
