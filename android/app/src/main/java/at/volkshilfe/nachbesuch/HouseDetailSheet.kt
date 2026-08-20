package at.volkshilfe.nachbesuch

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import at.volkshilfe.nachbesuch.ui.theme.GlassRow

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HouseDetailSheet(
    house: House,
    scope: DayScope,
    onScopeChange: (DayScope) -> Unit,
    onOutcome: (String, VisitOutcome?) -> Unit,
    onResize: (Int) -> Unit,
    onDelete: () -> Unit,
    onDismiss: () -> Unit
) {
    var countText by remember(house.id, house.units.size) { mutableStateOf(house.units.size.toString()) }
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
                        Column(Modifier.weight(1f)) {
                            Text(door.label, style = MaterialTheme.typography.titleMedium)
                            Text(
                                door.displayOutcome(scope)?.germanTitle ?: "Noch offen",
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Text(door.displayOutcome(scope)?.emoji ?: "○", style = MaterialTheme.typography.headlineSmall)
                    }
                    HorizontalDivider(Modifier.padding(vertical = 8.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        VisitOutcome.entries.forEach { outcome ->
                            TextButton(
                                onClick = { onOutcome(door.id, outcome) },
                                enabled = !house.isDamaged
                            ) { Text(outcome.emoji) }
                        }
                        TextButton(
                            onClick = { onOutcome(door.id, null) },
                            enabled = !house.isDamaged
                        ) { Text("Offen") }
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
}
