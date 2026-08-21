package at.volkshilfe.nachbesuch

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import at.volkshilfe.nachbesuch.domain.list.StreetNameParser
import at.volkshilfe.nachbesuch.domain.archive.ArchiveSearch
import at.volkshilfe.nachbesuch.domain.model.Gebiet
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.StoredCoordinate
import at.volkshilfe.nachbesuch.ui.theme.GlassCard
import at.volkshilfe.nachbesuch.ui.theme.GlassRow
import kotlinx.coroutines.flow.StateFlow

@Composable
fun ListSurface(viewModel: AppViewModel, onHouseSelected: (House) -> Unit) {
    val houses by viewModel.houses.collectAsStateWithLifecycleCompat()
    val territory by viewModel.activeGebiet.collectAsStateWithLifecycleCompat()
    val scope by viewModel.scope.collectAsStateWithLifecycleCompat()
    var query by rememberSaveable { mutableStateOf("") }
    val filtered = houses.filter { house -> query.trim().isEmpty() || ArchiveSearch.matches(query, listOf(house.address)) }
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        Spacer(Modifier.height(12.dp))
        Text("Nachbesuche", style = MaterialTheme.typography.headlineLarge)
        Text(territory?.displayName ?: "Kein Gebiet", color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(12.dp))
        OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
            placeholder = { Text("Adresse suchen") }
        )
        if (territory?.isTwoDay == true) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(vertical = 8.dp)) {
                listOf(DayScope.COMBINED to "Gesamt", DayScope.DAY_1 to "Tag 1", DayScope.DAY_2 to "Tag 2").forEach { (candidate, label) ->
                    FilterChip(selected = scope == candidate, onClick = { viewModel.selectScope(candidate) }, label = { Text(label) })
                }
            }
        }
        Spacer(Modifier.height(12.dp))
        if (filtered.isEmpty()) {
            GlassCard(Modifier.fillMaxWidth()) {
                Text("Noch keine Häuser", style = MaterialTheme.typography.titleLarge)
                Text("Füge auf der Karte ein Haus hinzu.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else {
            val grouped = filtered.groupBy { StreetNameParser.parse(it.address).first }
                .toSortedMap(String.CASE_INSENSITIVE_ORDER)
            LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                grouped.forEach { (street, rows) ->
                    item(key = "street-$street") {
                        Text(street, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(start = 4.dp, top = 4.dp))
                    }
                    items(rows, key = { it.id }) { house ->
                        HouseRow(house, scope, onClick = { onHouseSelected(house) })
                    }
                }
            }
        }
    }
}

@Composable
private fun HouseRow(house: House, scope: DayScope, onClick: () -> Unit) {
    val tally = house.tally(scope)
    GlassRow(Modifier.fillMaxWidth().clickable(onClick = onClick)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(house.address, style = MaterialTheme.typography.titleMedium)
                val status = if (tally.open > 0) "${tally.open} offen" else "Erledigt"
                Text(status, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text(
                if (house.isApartmentBuilding) "${tally.completed}/${tally.unitCount}" else house.units.firstOrNull()?.displayOutcome(scope)?.emoji ?: "○",
                style = MaterialTheme.typography.headlineSmall
            )
        }
    }
}

@Composable
fun ArchiveSurface(
    viewModel: AppViewModel,
    onCreateGebiet: () -> Unit,
    onExportBackup: () -> Unit,
    onExportPdf: () -> Unit,
    onExportText: () -> Unit,
    onImportBackup: () -> Unit
) {
    val gebiete by viewModel.gebiete.collectAsStateWithLifecycleCompat()
    val houses by viewModel.allHouses.collectAsStateWithLifecycleCompat()
    val activeID by viewModel.activeGebietID.collectAsStateWithLifecycleCompat()
    var pendingDelete by rememberSaveable { mutableStateOf<Gebiet?>(null) }
    var archiveQuery by rememberSaveable { mutableStateOf("") }
    val visibleGebiete = gebiete.filter { gebiet ->
        archiveQuery.isBlank() || ArchiveSearch.matches(archiveQuery, listOf(gebiet.displayName, gebiet.districtOrCity, gebiet.dateLabel()))
    }
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        Spacer(Modifier.height(12.dp))
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Archiv", style = MaterialTheme.typography.headlineLarge)
                Text("Alle Gebiete und Arbeitstage", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            FloatingActionButton(
                onClick = onCreateGebiet,
                containerColor = MaterialTheme.colorScheme.primary,
                contentColor = MaterialTheme.colorScheme.onPrimary
            ) {
                Icon(Icons.Default.Add, contentDescription = "Gebiet anlegen")
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton(onClick = onExportBackup, enabled = gebiete.isNotEmpty()) { Text("Backup JSON") }
            TextButton(onClick = onExportPdf, enabled = activeID != null) { Text("PDF") }
            TextButton(onClick = onExportText, enabled = activeID != null) { Text("Text") }
            TextButton(onClick = onImportBackup) { Text("Importieren") }
        }
        OutlinedTextField(
            value = archiveQuery,
            onValueChange = { archiveQuery = it },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
            placeholder = { Text("Archiv durchsuchen") }
        )
        Spacer(Modifier.height(12.dp))
        if (visibleGebiete.isEmpty()) {
            GlassCard(Modifier.fillMaxWidth()) {
                Text(if (gebiete.isEmpty()) "Noch kein Gebiet" else "Keine Treffer", style = MaterialTheme.typography.titleLarge)
                Text(if (gebiete.isEmpty()) "Lege dein erstes Gebiet an." else "Passe die Suche an.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                items(visibleGebiete, key = { it.id }) { gebiet ->
                    val count = houses.count { it.gebietID == gebiet.id }
                    val open = houses.filter { it.gebietID == gebiet.id }.sumOf { it.tally.open }
                    GlassRow(
                        Modifier.fillMaxWidth().clickable { viewModel.selectGebiet(gebiet.id) }
                    ) {
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(gebiet.displayName, style = MaterialTheme.typography.titleLarge)
                                Text(
                                    "${gebiet.dateLabel()} · $count Häuser · $open offen" + if (gebiet.id == activeID) " · Aktiv" else "",
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            IconButton(onClick = { pendingDelete = gebiet }) {
                                Icon(Icons.Default.DeleteOutline, contentDescription = "Gebiet löschen")
                            }
                        }
                    }
                }
            }
        }
    }
    pendingDelete?.let { gebiet ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Gebiet löschen?") },
            text = { Text("${gebiet.displayName} und alle zugehörigen Häuser werden gelöscht.") },
            confirmButton = {
                TextButton(onClick = { viewModel.deleteGebiet(gebiet.id); pendingDelete = null }) {
                    Text("Löschen", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("Abbrechen") } }
        )
    }
}

@Composable
fun CreateGebietDialog(onCreate: (String, String, Boolean) -> Unit, onDismiss: () -> Unit) {
    var name by rememberSaveable { mutableStateOf("") }
    var district by rememberSaveable { mutableStateOf("") }
    var twoDay by rememberSaveable { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Gebiet anlegen") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true)
                OutlinedTextField(district, { district = it }, label = { Text("Ort (optional)") }, singleLine = true)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = twoDay, onCheckedChange = { twoDay = it })
                    Text("Zwei Arbeitstage")
                }
            }
        },
        confirmButton = {
            Button(onClick = { onCreate(name, district, twoDay) }, enabled = name.trim().isNotEmpty()) { Text("Anlegen") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Abbrechen") } }
    )
}

@Composable
fun AddHouseDialog(
    coordinate: StoredCoordinate,
    onAdd: (String, StoredCoordinate) -> Unit,
    onDismiss: () -> Unit
) {
    var address by rememberSaveable { mutableStateOf("") }
    var latitude by rememberSaveable(coordinate.latitude) { mutableStateOf("%.6f".format(coordinate.latitude)) }
    var longitude by rememberSaveable(coordinate.longitude) { mutableStateOf("%.6f".format(coordinate.longitude)) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Haus hinzufügen") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(address, { address = it }, label = { Text("Adresse") }, singleLine = true)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(latitude, { latitude = it }, label = { Text("Breite") }, singleLine = true, modifier = Modifier.weight(1f), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
                    OutlinedTextField(longitude, { longitude = it }, label = { Text("Länge") }, singleLine = true, modifier = Modifier.weight(1f), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
                }
                Text("Position: ${coordinate.latitude.formatCoordinate()}, ${coordinate.longitude.formatCoordinate()}", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        confirmButton = {
            Button(onClick = {
                val lat = latitude.replace(',', '.').toDoubleOrNull()
                val lon = longitude.replace(',', '.').toDoubleOrNull()
                if (lat != null && lon != null) onAdd(address, StoredCoordinate(lat, lon))
            }, enabled = address.trim().isNotEmpty()) { Text("Hinzufügen") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Abbrechen") } }
    )
}

private fun Double.formatCoordinate(): String = "%.5f".format(this)

@Composable
fun <T> StateFlow<T>.collectAsStateWithLifecycleCompat(): androidx.compose.runtime.State<T> =
    collectAsState()
