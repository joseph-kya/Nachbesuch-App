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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import at.volkshilfe.nachbesuch.domain.archive.ArchiveSearch
import at.volkshilfe.nachbesuch.domain.archive.ArchiveSearchEngine
import at.volkshilfe.nachbesuch.domain.list.StreetNameParser
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.Gebiet
import at.volkshilfe.nachbesuch.domain.model.House
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
    // Filter + grouping run once per (houses, query) change, not per frame.
    val filtered = remember(houses, query) {
        houses.filter { house -> query.trim().isEmpty() || ArchiveSearch.matches(query, listOf(house.address)) }
    }
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
            val grouped = remember(filtered) {
                filtered.groupBy { StreetNameParser.parse(it.address).first.ifBlank { "Sonstige" } }
                    .toSortedMap(String.CASE_INSENSITIVE_ORDER)
            }
            LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                grouped.forEach { (street, rows) ->
                    item(key = "street-$street") {
                        Row(
                            Modifier.fillMaxWidth().padding(start = 4.dp, top = 6.dp, bottom = 2.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(street, style = MaterialTheme.typography.titleMedium)
                            Spacer(Modifier.width(8.dp))
                            Text(
                                "${rows.size}",
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
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
private fun ExportToolbarButton(label: String, enabled: Boolean = true, onClick: () -> Unit) {
    TextButton(onClick = onClick, enabled = enabled) { Text(label) }
}

@Composable
fun ArchiveSurface(
    viewModel: AppViewModel,
    onCreateGebiet: () -> Unit,
    onExportBackup: () -> Unit,
    onExportPdf: () -> Unit,
    onExportText: () -> Unit,
    onExportLegacy: () -> Unit,
    onImportBackup: () -> Unit
) {
    val summaries by viewModel.summaries.collectAsStateWithLifecycleCompat()
    val activeID by viewModel.activeGebietID.collectAsStateWithLifecycleCompat()
    var pendingDelete by rememberSaveable { mutableStateOf<Gebiet?>(null) }
    var archiveQuery by rememberSaveable { mutableStateOf("") }
    val visibleSummaries = remember(summaries, archiveQuery) {
        if (archiveQuery.isBlank()) summaries else ArchiveSearchEngine.search(archiveQuery, summaries)
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
        // The export action row as one contained toolbar instead of loose links.
        Surface(
            modifier = Modifier.fillMaxWidth().padding(top = 10.dp),
            shape = MaterialTheme.shapes.large,
            color = MaterialTheme.colorScheme.surfaceContainer
        ) {
            Column(Modifier.padding(horizontal = 8.dp, vertical = 6.dp)) {
                Text(
                    "Aktives Gebiet exportieren",
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                    ExportToolbarButton("PDF-Bericht", enabled = activeID != null, onClick = onExportPdf)
                    ExportToolbarButton("Textbericht", enabled = activeID != null, onClick = onExportText)
                    ExportToolbarButton("Legacy-Liste", enabled = activeID != null, onClick = onExportLegacy)
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Start) {
                    ExportToolbarButton("Backup", enabled = summaries.isNotEmpty(), onClick = onExportBackup)
                    ExportToolbarButton("Backup importieren", onClick = onImportBackup)
                }
            }
        }
        OutlinedTextField(
            value = archiveQuery,
            onValueChange = { archiveQuery = it },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
            placeholder = { Text("z. B. „offen“, „heute“, „dabei“ oder ein Name") }
        )
        Spacer(Modifier.height(12.dp))
        if (visibleSummaries.isEmpty()) {
            GlassCard(Modifier.fillMaxWidth()) {
                Text(if (summaries.isEmpty()) "Noch kein Gebiet" else "Keine Treffer", style = MaterialTheme.typography.titleLarge)
                Text(
                    if (summaries.isEmpty()) "Lege dein erstes Gebiet an."
                    else "Versuche „offen“, „dabei“, „nachbesuch“ oder einen Ort.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                items(visibleSummaries, key = { it.territory.id }) { summary ->
                    TerritoryRow(
                        summary = summary,
                        isActive = summary.territory.id == activeID,
                        onClick = { viewModel.selectGebiet(summary.territory.id) },
                        onDeleteClick = { pendingDelete = summary.territory }
                    )
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
private fun TerritoryRow(
    summary: at.volkshilfe.nachbesuch.domain.stats.TerritorySummary,
    isActive: Boolean,
    onClick: () -> Unit,
    onDeleteClick: () -> Unit
) {
    val territory = summary.territory
    val bilanz = summary.bilanz
    GlassRow(Modifier.fillMaxWidth().clickable(onClick = onClick)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(territory.displayName, style = MaterialTheme.typography.titleLarge)
                    if (isActive) {
                        Surface(color = MaterialTheme.colorScheme.primaryContainer, shape = MaterialTheme.shapes.small) {
                            Text(
                                "Aktiv",
                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onPrimaryContainer
                            )
                        }
                    }
                }
                Text(
                    listOfNotNull(territory.formattedDateRange(), "${summary.houseCount} Häuser").joinToString(" · "),
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(Modifier.height(6.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    StatPill("Offen", bilanz.overall.open.toString())
                    StatPill("Dabei", bilanz.overall.joined.toString())
                    if (territory.isTwoDay) {
                        StatPill("Tag 1", "${bilanz.day1.completed}/${bilanz.day1.unitCount}")
                        StatPill("Tag 2", "${bilanz.day2.completed}/${bilanz.revisitTargets}")
                        if (bilanz.pendingRevisits > 0) {
                            StatPill("Nachbesuche", bilanz.pendingRevisits.toString(), highlight = true)
                        }
                    }
                }
            }
            IconButton(onClick = onDeleteClick) {
                Icon(Icons.Default.DeleteOutline, contentDescription = "Gebiet löschen")
            }
        }
    }
}

@Composable
private fun StatPill(label: String, value: String, highlight: Boolean = false) {
    Surface(
        color = if (highlight) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainerHighest,
        shape = MaterialTheme.shapes.small
    ) {
        Row(Modifier.padding(horizontal = 8.dp, vertical = 3.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(
                value,
                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                color = if (highlight) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurface
            )
            Spacer(Modifier.width(4.dp))
            Text(
                label,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
fun ExportOptionsDialog(onConfirm: (ExportOptions) -> Unit, onDismiss: () -> Unit) {
    var visitedOnly by rememberSaveable { mutableStateOf(true) }
    var includeNotes by rememberSaveable { mutableStateOf(true) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Exportoptionen") },
        text = {
            Column {
                CheckboxRow("Nur besuchte Adressen", visitedOnly) { visitedOnly = it }
                CheckboxRow("Notizen einschließen", includeNotes) { includeNotes = it }
            }
        },
        confirmButton = {
            Button(onClick = { onConfirm(ExportOptions(visitedOnly, includeNotes)) }) { Text("Exportieren") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Abbrechen") } }
    )
}

@Composable
private fun CheckboxRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Checkbox(checked = checked, onCheckedChange = onChange)
        Text(label)
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
    var editCoordinates by rememberSaveable { mutableStateOf(false) }
    var latitude by rememberSaveable(coordinate.latitude) { mutableStateOf("%.6f".format(coordinate.latitude)) }
    var longitude by rememberSaveable(coordinate.longitude) { mutableStateOf("%.6f".format(coordinate.longitude)) }

    fun parsedCoordinate(): StoredCoordinate? {
        if (!editCoordinates) return coordinate
        val lat = latitude.replace(',', '.').toDoubleOrNull() ?: return null
        val lon = longitude.replace(',', '.').toDoubleOrNull() ?: return null
        return StoredCoordinate(lat, lon).takeIf(StoredCoordinate::isPlausible)
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Haus hinzufügen") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(address, { address = it }, label = { Text("Adresse") }, singleLine = true)
                if (!editCoordinates) {
                    Text(
                        "Position: ${coordinate.latitude.formatCoordinate()}, ${coordinate.longitude.formatCoordinate()}",
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    TextButton(onClick = { editCoordinates = true }) { Text("Koordinaten korrigieren") }
                } else {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedTextField(latitude, { latitude = it }, label = { Text("Breite") }, singleLine = true, modifier = Modifier.weight(1f), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
                        OutlinedTextField(longitude, { longitude = it }, label = { Text("Länge") }, singleLine = true, modifier = Modifier.weight(1f), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
                    }
                }
            }
        },
        confirmButton = {
            Button(
                onClick = { parsedCoordinate()?.let { onAdd(address, it) } },
                enabled = address.trim().isNotEmpty()
            ) { Text("Hinzufügen") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Abbrechen") } }
    )
}

private fun Double.formatCoordinate(): String = "%.5f".format(this)

@Composable
fun <T> StateFlow<T>.collectAsStateWithLifecycleCompat(): androidx.compose.runtime.State<T> =
    collectAsState()
